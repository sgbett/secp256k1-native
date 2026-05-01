/*
 * ruby.h — Minimal stub header for the timing harness.
 *
 * Provides just enough type definitions and macros for
 * secp256k1_native.h to compile without the real Ruby headers.
 * No Ruby API functions are declared here — the linker resolves
 * those symbols via ruby_stubs.c.
 */

#ifndef RUBY_STUB_H
#define RUBY_STUB_H

#include <stdint.h>
#include <stddef.h>

/* VALUE is an unsigned pointer-width integer in CRuby. */
typedef uintptr_t VALUE;

/* Integer packing flags — values match CRuby's internal definitions. */
#define INTEGER_PACK_LSWORD_FIRST      0x01
#define INTEGER_PACK_NATIVE_BYTE_ORDER 0x40

/* Ruby special values */
#define Qnil  ((VALUE)0x08)
#define Qtrue ((VALUE)0x14)

/* Type checking — T_ARRAY tag and Check_Type macro */
#define T_ARRAY 0x07
#define Check_Type(v, t) rb_check_type((v), (t))
extern void rb_check_type(VALUE, int);

/* RTEST — truthy check (anything that is not Qfalse or Qnil) */
#define Qfalse ((VALUE)0x00)
#define RTEST(v) (((VALUE)(v) & ~Qnil) != 0)

/* INT2FIX — convert small C int to a Ruby Fixnum (immediate value) */
#define INT2FIX(i) ((VALUE)(((long)(i) << 1) | 1))

/* Array operations */
extern VALUE rb_ary_new_capa(long capa);
extern VALUE rb_ary_push(VALUE ary, VALUE item);
extern VALUE rb_ary_entry(VALUE ary, long offset);
#define RARRAY_LEN(a) 0  /* never evaluated in harness code paths */

/* Error class globals */
extern VALUE rb_eRuntimeError;
extern VALUE rb_eArgError;
extern VALUE rb_cInteger;

/* Integer marshalling */
extern int   rb_integer_pack(VALUE val, void *words, size_t numwords,
                             size_t wordsize, size_t nails, int flags);
extern VALUE rb_integer_unpack(const void *words, size_t numwords,
                               size_t wordsize, size_t nails, int flags);

/* Error raising */
extern void rb_raise(VALUE exc, const char *fmt, ...)
    __attribute__((format(printf, 2, 3), noreturn));

/* Method dispatch and interning */
extern VALUE rb_funcall(VALUE recv, VALUE mid, int argc, ...);
extern VALUE rb_intern(const char *name);

/* Module and method definition */
extern VALUE rb_define_module(const char *name);
extern void  rb_define_module_function(VALUE mod, const char *name,
                                       VALUE (*func)(), int argc);

#endif /* RUBY_STUB_H */
