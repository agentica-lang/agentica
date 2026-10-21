/* A library with a symbol that nothing defines (tests/test_vm_native.py): the VM opens libraries with RTLD_NOW, so
   loading it is RUNTIME-NATIVE-LOAD instead of the dynamic linker ending the process at the first call. */
int agentica_test_nowhere(void);

int unbound_call(void) { return agentica_test_nowhere(); }
