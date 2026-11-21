#include <assert.h>
#include <stdio.h>
#include "DSHRHStartupState.h"

int main(void) {
    DSHRHStartupState state = {0};
    assert(!DSHRHStartupCanPresentFallback(&state, true, false, false));
    DSHRHStartupBegin(&state);
    // Regression: WebContent dies immediately, while the helper is still running.
    DSHRHStartupRequestFallback(&state);
    assert(!DSHRHStartupCanPresentFallback(&state, true, false, false));
    assert(state.fallbackPending);
    DSHRHStartupComplete(&state);
    // The target URL is refreshed by the caller before completing startup.
    assert(!DSHRHStartupCanPresentFallback(&state, false, false, false));
    assert(!DSHRHStartupCanPresentFallback(&state, true, true, false));
    assert(DSHRHStartupCanPresentFallback(&state, true, false, false));
    assert(!DSHRHStartupCanPresentFallback(&state, true, false, true));
    // A deliberate retry starts a new gated attempt.
    DSHRHStartupBegin(&state);
    assert(!state.fallbackPending);
    assert(!DSHRHStartupCanPresentFallback(&state, true, false, false));
    DSHRHStartupComplete(&state);
    assert(!DSHRHStartupCanPresentFallback(&state, true, false, false));
    DSHRHStartupRequestFallback(&state);
    assert(DSHRHStartupCanPresentFallback(&state, true, false, false));
    puts("PASS: early WebContent failure, view attachment, modal state and retry ordering");
    return 0;
}
