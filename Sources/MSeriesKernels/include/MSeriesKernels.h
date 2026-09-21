#ifndef MSC_KERNELS_H
#define MSC_KERNELS_H
#include <stdint.h>
#include <stddef.h>
// Fixed workload units; dimension/precision never depend on hardware.
// 0 integer, 1 floating, 2 LZFSE compression, 3 image, 4 copy, 5 triad, 6 pointer chase.
typedef struct MSCWorkspace MSCWorkspace;
MSCWorkspace *msc_create(int kind);
void msc_destroy(MSCWorkspace *workspace);
int msc_run_unit(MSCWorkspace *workspace);
int msc_validate(MSCWorkspace *workspace);
uint64_t msc_checksum(MSCWorkspace *workspace);
uint64_t msc_unit_bytes(int kind);
uint64_t msc_resident_bytes(int kind);
uint64_t msc_accesses(int kind);
#endif
