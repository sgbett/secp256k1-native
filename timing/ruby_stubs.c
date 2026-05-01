/*
 * ruby_stubs.c — Stub definitions for Ruby API symbols.
 *
 * The C extension source files (field.c, scalar.c, jacobian.c) contain
 * Ruby-facing wrapper functions that reference Ruby API symbols.  The
 * timing harness only calls *_internal functions (which operate on
 * uint256_t structs directly), but the linker still needs all symbols
 * resolved.
 *
 * Every stub aborts with a diagnostic message if called — this indicates
 * a bug in the harness (it should never reach Ruby API code paths).
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>

/* VALUE is an unsigned pointer-width integer in Ruby.  We only need
 * the type to exist so the extension source compiles. */
typedef uintptr_t VALUE;

/* Ruby type tag constants — never inspected, just need to exist. */
#define T_ARRAY 0x07

/* Ruby special values */
VALUE rb_cInteger;
VALUE rb_eRuntimeError;
VALUE rb_eArgError;

/* Module handle declared extern in secp256k1_native.h */
VALUE rb_mSecp256k1Native;

/* INTEGER_PACK flags — the header uses these in a macro definition.
 * Values match CRuby's internal.h but are never evaluated. */
#define INTEGER_PACK_LSWORD_FIRST    0x01
#define INTEGER_PACK_NATIVE_BYTE_ORDER 0x40

static void stub_abort(const char *name)
{
    fprintf(stderr,
            "FATAL: Ruby API stub '%s' was called.\n"
            "The timing harness must only call *_internal functions.\n"
            "This indicates a bug in the harness.\n", name);
    abort();
}

/* -----------------------------------------------------------------------
 * Integer marshalling
 * ----------------------------------------------------------------------- */

int rb_integer_pack(VALUE val, void *words, size_t numwords,
                    size_t wordsize, size_t nails, int flags)
{
    (void)val; (void)words; (void)numwords;
    (void)wordsize; (void)nails; (void)flags;
    stub_abort("rb_integer_pack");
    return 0;
}

VALUE rb_integer_unpack(const void *words, size_t numwords,
                        size_t wordsize, size_t nails, int flags)
{
    (void)words; (void)numwords;
    (void)wordsize; (void)nails; (void)flags;
    stub_abort("rb_integer_unpack");
    return 0;
}

/* -----------------------------------------------------------------------
 * Error raising
 * ----------------------------------------------------------------------- */

void rb_raise(VALUE exc, const char *fmt, ...)
{
    (void)exc; (void)fmt;
    stub_abort("rb_raise");
}

/* -----------------------------------------------------------------------
 * Method dispatch and interning
 * ----------------------------------------------------------------------- */

VALUE rb_funcall(VALUE recv, VALUE mid, int argc, ...)
{
    (void)recv; (void)mid; (void)argc;
    stub_abort("rb_funcall");
    return 0;
}

VALUE rb_intern(const char *name)
{
    (void)name;
    stub_abort("rb_intern");
    return 0;
}

/* -----------------------------------------------------------------------
 * Module and method definition
 * ----------------------------------------------------------------------- */

VALUE rb_define_module(const char *name)
{
    (void)name;
    stub_abort("rb_define_module");
    return 0;
}

void rb_define_module_function(VALUE mod, const char *name,
                               VALUE (*func)(), int argc)
{
    (void)mod; (void)name; (void)func; (void)argc;
    stub_abort("rb_define_module_function");
}

/* -----------------------------------------------------------------------
 * Array operations
 * ----------------------------------------------------------------------- */

VALUE rb_ary_new_capa(long capa)
{
    (void)capa;
    stub_abort("rb_ary_new_capa");
    return 0;
}

VALUE rb_ary_push(VALUE ary, VALUE item)
{
    (void)ary; (void)item;
    stub_abort("rb_ary_push");
    return 0;
}

VALUE rb_ary_entry(VALUE ary, long offset)
{
    (void)ary; (void)offset;
    stub_abort("rb_ary_entry");
    return 0;
}

/* -----------------------------------------------------------------------
 * Type checking
 * ----------------------------------------------------------------------- */

void rb_check_type(VALUE val, int type)
{
    (void)val; (void)type;
    stub_abort("rb_check_type");
}

/* -----------------------------------------------------------------------
 * Init entry point — never called from the harness
 * ----------------------------------------------------------------------- */

void Init_secp256k1_native(void);
