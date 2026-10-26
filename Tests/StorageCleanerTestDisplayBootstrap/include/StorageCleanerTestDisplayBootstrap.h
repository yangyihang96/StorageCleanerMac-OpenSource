#ifndef STORAGE_CLEANER_TEST_DISPLAY_BOOTSTRAP_H
#define STORAGE_CLEANER_TEST_DISPLAY_BOOTSTRAP_H

/// D106: 1 once this object is linked into the test bundle; its load-time
/// constructor has then installed the display gate before any test ran.
int storage_cleaner_test_display_bootstrap_linked(void);

#endif
