import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SERVICE_DIR = ROOT / "scripts" / "vphoned"


class VphonedServiceStateRuntimeTests(unittest.TestCase):
    def test_concurrent_startup_snapshot_and_request_gates(self) -> None:
        source = textwrap.dedent(
            r"""
            #include <assert.h>
            #include <pthread.h>
            #include <stdbool.h>
            #include <stdatomic.h>
            #include <stdint.h>
            #include <stdio.h>
            #include <time.h>
            #include <unistd.h>

            #include "vphoned_service_state.h"

            typedef struct {
              VPServiceState *state;
              useconds_t delay_us;
              bool available;
              atomic_bool completed;
              atomic_bool published;
            } Loader;

            static void *run_loader(void *context) {
              Loader *loader = context;
              usleep(loader->delay_us);
              bool published = vp_service_complete(loader->state, loader->available);
              atomic_store_explicit(&loader->published, published, memory_order_release);
              atomic_store_explicit(&loader->completed, true, memory_order_release);
              return NULL;
            }

            static void gated_handler(VPServiceState *state, atomic_int *calls) {
              if (vp_service_available(state))
                atomic_fetch_add_explicit(calls, 1, memory_order_relaxed);
            }

            static uint64_t monotonic_ms(void) {
              struct timespec value;
              clock_gettime(CLOCK_MONOTONIC, &value);
              return (uint64_t)value.tv_sec * 1000 + (uint64_t)value.tv_nsec / 1000000;
            }

            int main(void) {
              VPServiceState hid = VP_SERVICE_STATE_INITIALIZER;
              VPServiceState clipboard = VP_SERVICE_STATE_INITIALIZER;
              VPServiceState apps = VP_SERVICE_STATE_INITIALIZER;
              Loader loaders[] = {
                {&hid, 250000, true, false, false},
                {&clipboard, 1000, true, false, false},
                {&apps, 1000, true, false, false},
              };
              pthread_t threads[3];
              uint64_t started = monotonic_ms();

              for (int i = 0; i < 3; i++)
                assert(pthread_create(&threads[i], NULL, run_loader, &loaders[i]) == 0);

              usleep(50000);
              vp_service_expire(&hid);
              vp_service_expire(&clipboard);
              vp_service_expire(&apps);
              uint64_t snapshot_ms = monotonic_ms() - started;

              assert(snapshot_ms < 200);
              assert(!atomic_load_explicit(&loaders[0].completed, memory_order_acquire));
              assert(vp_service_available(&clipboard));
              assert(vp_service_available(&apps));
              assert(!vp_service_available(&hid));

              atomic_int hid_calls = ATOMIC_VAR_INIT(0);
              atomic_int app_calls = ATOMIC_VAR_INIT(0);
              gated_handler(&hid, &hid_calls);
              gated_handler(&apps, &app_calls);
              assert(atomic_load_explicit(&hid_calls, memory_order_relaxed) == 0);
              assert(atomic_load_explicit(&app_calls, memory_order_relaxed) == 1);

              for (int i = 0; i < 3; i++)
                assert(pthread_join(threads[i], NULL) == 0);

              assert(!atomic_load_explicit(&loaders[0].published, memory_order_acquire));
              assert(!vp_service_available(&hid));
              puts("service-state-runtime: ok");
              return 0;
            }
            """
        )

        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_path = Path(temporary_directory)
            source_path = temporary_path / "service_state_test.c"
            binary_path = temporary_path / "service_state_test"
            source_path.write_text(source)
            compile_result = subprocess.run(
                [
                    "xcrun",
                    "clang",
                    "-std=c11",
                    "-Wall",
                    "-Wextra",
                    "-Werror",
                    "-pthread",
                    "-I",
                    str(SERVICE_DIR),
                    str(source_path),
                    "-o",
                    str(binary_path),
                ],
                capture_output=True,
                text=True,
            )
            self.assertEqual(compile_result.returncode, 0, compile_result.stderr)

            run_result = subprocess.run(
                [str(binary_path)],
                capture_output=True,
                text=True,
                timeout=2,
            )
            self.assertEqual(run_result.returncode, 0, run_result.stderr)
            self.assertIn("service-state-runtime: ok", run_result.stdout)


if __name__ == "__main__":
    unittest.main()
