#include "StorageCleanerTestDisplayBootstrap.h"

// Defined by the test target (TestDisplayGateBootstrap.swift).
extern void storage_cleaner_install_test_display_gate(void);

// D106: runs when xctest loads the test bundle, before any test class is
// set up, so every window a test orders goes through the display gate.
__attribute__((constructor, used))
static void storage_cleaner_test_display_bootstrap(void) {
    storage_cleaner_install_test_display_gate();
}

int storage_cleaner_test_display_bootstrap_linked(void) {
    return 1;
}
