/* The library that unbound.c imports agentica_test_nowhere from on Windows (tests/test_vm_native.py), where a DLL
   cannot be linked with an undefined symbol: the test links unbound.dll against a nowhere.dll built with
   AGENTICA_TEST_DEFINE_NOWHERE, then builds nowhere.dll again without it, so loading unbound.dll fails. */
#ifdef AGENTICA_TEST_DEFINE_NOWHERE
int agentica_test_nowhere(void) { return 1; }
#endif

int agentica_test_somewhere(void) { return 0; }
