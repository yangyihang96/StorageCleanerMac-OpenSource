#include "MSeriesKernels.h"
#include <compression.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

struct MSCWorkspace {
    int kind;
    size_t n, result_size;
    void *a, *b, *out, *scratch;
    uint32_t chase_result;
};
static uint64_t mix(uint64_t x) {
    x ^= x >> 30; x *= UINT64_C(0xbf58476d1ce4e5b9);
    x ^= x >> 27; x *= UINT64_C(0x94d049bb133111eb);
    return x ^ (x >> 31);
}
uint64_t msc_resident_bytes(int kind) {
    switch(kind) {
        case 0: return 8 * 1024 * 1024;
        case 1: return 1024 * 1024;
        case 2: return 16 * 1024 * 1024;
        case 3: return 2 * 1024 * 1024;
        case 4: case 5: return 96 * 1024 * 1024;
        case 6: return 33 * 1024 * 1024;
        default: return 0;
    }
}
MSCWorkspace *msc_create(int kind) {
    if (kind < 0 || kind > 6) return NULL;
    MSCWorkspace *w = calloc(1, sizeof(*w));
    if (!w) return NULL;
    w->kind = kind;
    size_t bytes = 0;
    switch(kind) {
        case 0: w->n = 262144; bytes = w->n * sizeof(uint64_t); break;
        case 1: w->n = 128; bytes = 128 * 128 * sizeof(float); break;
        case 2: w->n = 1024 * 1024; bytes = w->n * 2; break;
        case 3: w->n = 512; bytes = 512 * 512; break;
        case 4: case 5: w->n = 4 * 1024 * 1024; bytes = w->n * sizeof(double); break;
        case 6: w->n = 4 * 1024 * 1024; bytes = w->n * sizeof(uint32_t); break;
    }
    w->a = malloc(bytes); w->b = malloc(bytes); w->out = kind == 6 ? NULL : malloc(bytes);
    if (!w->a || !w->b || (kind != 6 && !w->out)) { msc_destroy(w); return NULL; }
    if(kind == 0) {
        for(size_t i=0;i<w->n;i++) ((uint64_t*)w->a)[i] = (uint64_t)i + UINT64_C(0x619a27de);
    } else if(kind == 1) {
        for(size_t i=0;i<128*128;i++) {
            ((float*)w->a)[i] = (float)((i * 13 + 7) % 31) / 32.0f;
            ((float*)w->b)[i] = (float)((i * 17 + 3) % 29) / 32.0f;
        }
    } else if(kind == 2) {
        for(size_t i=0;i<w->n;i++) ((uint8_t*)w->a)[i] = (uint8_t)((i % 4096 < 3072) ? i % 251 : mix(i));
        w->scratch = malloc(compression_encode_scratch_buffer_size(COMPRESSION_LZFSE));
        if(!w->scratch) { msc_destroy(w); return NULL; }
    } else if(kind == 3) {
        for(size_t y=0;y<512;y++) for(size_t x=0;x<512;x++) ((uint8_t*)w->a)[y*512+x]=(x*13+y*7)%256;
    } else if(kind == 4 || kind == 5) {
        for(size_t i=0;i<w->n;i++) {
            ((double*)w->a)[i] = (double)(i % 1024) / 4.0;
            ((double*)w->b)[i] = (double)(i % 512) / 8.0;
        }
    } else {
        w->chase_result=UINT32_MAX;
        w->scratch=calloc((w->n+7)/8,1);
        if(!w->scratch) { msc_destroy(w); return NULL; }
        uint32_t *order=w->b, *next=w->a;
        for(size_t i=0;i<w->n;i++) order[i]=(uint32_t)i;
        uint64_t rng=UINT64_C(0x619a27de);
        for(size_t i=w->n-1;i>0;i--) {
            rng=mix(rng); size_t j=rng%(i+1); uint32_t tmp=order[i];order[i]=order[j];order[j]=tmp;
        }
        for(size_t i=0;i<w->n;i++) next[order[i]]=order[(i+1)%w->n];
    }
    return w;
}
void msc_destroy(MSCWorkspace *w) {
    if(!w) return;
    free(w->a); free(w->b); free(w->out); free(w->scratch); free(w);
}
__attribute__((noinline)) int msc_run_unit(MSCWorkspace *w) {
    if(!w) return 0;
    switch(w->kind) {
        case 0:
            for(size_t i=0;i<w->n;i++) ((uint64_t*)w->out)[i]=mix(((uint64_t*)w->a)[i]);
            break;
        case 1: {
            float *a=w->a,*b=w->b,*c=w->out;
            for(size_t i=0;i<128;i++) for(size_t j=0;j<128;j++) {
                float sum=0; for(size_t k=0;k<128;k++) sum+=a[i*128+k]*b[k*128+j];
                c[i*128+j]=sum;
            }
            break;
        }
        case 2:
            w->result_size=compression_encode_buffer(w->out,w->n*2,w->a,w->n,w->scratch,COMPRESSION_LZFSE);
            if(w->result_size==0) return 0;
            break;
        case 3: {
            uint8_t *in=w->a,*out=w->out;
            memset(out,0,512*512);
            for(size_t y=1;y<511;y++) for(size_t x=1;x<511;x++) {
                size_t p=y*512+x;
                unsigned sum=in[p-513]+2*in[p-512]+in[p-511]+2*in[p-1]+4*in[p]+2*in[p+1]+in[p+511]+2*in[p+512]+in[p+513];
                out[p]=(uint8_t)(sum/16);
            }
            break;
        }
        case 4: memcpy(w->out,w->a,w->n*sizeof(double)); break;
        case 5: {
            double *a=w->a,*b=w->b,*c=w->out;
            for(size_t i=0;i<w->n;i++) c[i]=a[i]+3.0*b[i];
            break;
        }
        case 6: {
            volatile uint32_t *next=w->a; uint32_t position=0;
            for(size_t i=0;i<w->n;i++) position=next[position];
            w->chase_result=position; break;
        }
    }
    return 1;
}
int msc_validate(MSCWorkspace *w) {
    if(!w) return 0;
    switch(w->kind) {
        case 0:
            for(size_t i=0;i<w->n;i++) if(((uint64_t*)w->out)[i]!=mix(i+UINT64_C(0x619a27de))) return 0;
            return 1;
        case 1:
            for(size_t i=0;i<128;i++) for(size_t j=0;j<128;j++) {
                double sum=0;
                // Independent double-precision reference from fixed fixture formula.
                for(size_t k=0;k<128;k++) sum+=(double)(((i*128+k)*13+7)%31)*(double)(((k*128+j)*17+3)%29)/1024.0;
                if(!isfinite(((float*)w->out)[i*128+j]) || fabs(((float*)w->out)[i*128+j]-sum)>0.0001) return 0;
            }
            return 1;
        case 2: {
            size_t decoded=compression_decode_buffer(w->b,w->n,w->out,w->result_size,NULL,COMPRESSION_LZFSE);
            return decoded==w->n && memcmp(w->a,w->b,w->n)==0;
        }
        case 3:
            for(int y=0;y<512;y++) for(int x=0;x<512;x++) {
                unsigned expected=0;
                if(x>0&&x<511&&y>0&&y<511) {
                    for(int dy=-1;dy<=1;dy++) for(int dx=-1;dx<=1;dx++)
                        expected+=(((x+dx)*13+(y+dy)*7)%256)*(dx==0?2:1)*(dy==0?2:1);
                    expected/=16;
                }
                if(((uint8_t*)w->out)[y*512+x]!=expected) return 0;
            }
            return 1;
        case 4: return memcmp(w->a,w->out,w->n*sizeof(double))==0;
        case 5:
            for(size_t i=0;i<w->n;i++) if(((double*)w->out)[i]!=(double)(i%1024)/4.0+3.0*(double)(i%512)/8.0) return 0;
            return 1;
        case 6: {
            if(w->chase_result!=0) return 0;
            // Validate the entire permutation and every link, outside timing.
            // Returning to zero alone would also accept a short/broken cycle.
            uint32_t *order=w->b, *next=w->a;
            uint8_t *seen=w->scratch;
            memset(seen,0,(w->n+7)/8);
            for(size_t i=0;i<w->n;i++) {
                uint32_t p=order[i];
                if(p>=w->n || (seen[p/8] & (1u<<(p%8)))) return 0;
                seen[p/8] |= (uint8_t)(1u<<(p%8));
                if(next[p]!=order[(i+1)%w->n]) return 0;
            }
            return 1;
        }
    }
    return 0;
}
uint64_t msc_checksum(MSCWorkspace *w) {
    if(w->kind==6) {
        uint64_t hash=UINT64_C(14695981039346656037);
        for(size_t i=0;i<w->n;i++) {hash^=((uint32_t*)w->a)[i];hash*=UINT64_C(1099511628211);}
        return hash ^ w->chase_result;
    }
    size_t size=w->kind==0?w->n*8:w->kind==1?128*128*4:w->kind==2?w->result_size:w->kind==3?512*512:w->n*8;
    uint64_t hash=UINT64_C(14695981039346656037);
    for(size_t i=0;i<size;i++) {hash^=((uint8_t*)w->out)[i];hash*=UINT64_C(1099511628211);}
    return hash;
}
uint64_t msc_unit_bytes(int kind) {
    if(kind==4) return UINT64_C(64)*1024*1024;
    if(kind==5) return UINT64_C(96)*1024*1024;
    return 0;
}
uint64_t msc_accesses(int kind) {return kind==6?4*1024*1024:0;}
