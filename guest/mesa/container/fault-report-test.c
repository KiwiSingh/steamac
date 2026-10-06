// Verification helper for fault-report.so (verify.sh): faults in a known function, after
// installing and then restoring its own SIGSEGV handler the way games' crash handlers do.
#include <signal.h>
#include <stdio.h>
#include <unistd.h>

static void game_handler(int sig) {
    static const char msg[] = "fault-report-test: game handler ran\n";
    if (write(2, msg, sizeof msg - 1) < 0) {}
    signal(sig, SIG_DFL);
}

__attribute__((noinline)) void fault_report_test_crash(volatile int *p) { *p = 42; }

int main(void) {
    signal(SIGSEGV, game_handler);
    fault_report_test_crash((volatile int *)0x1234);
    puts("fault-report-test: no fault");
    return 0;
}
