#include "secp256k1_native.h"

/*
 * Secp256k1Native
 *
 * Native C extension providing accelerated secp256k1 field, scalar, and point
 * arithmetic. Methods are registered here as tasks are implemented; the module
 * is intentionally empty at scaffold stage.
 *
 * The extension is designed to be used standalone or as a dependency of the
 * bsv-sdk gem, which delegates hot-path operations to this module when available.
 */

/* Module handle — set during Init, used by sub-files when they register methods. */
VALUE rb_mSecp256k1Native;

/*
 * Entry point called by Ruby when the extension is required.
 *
 * Defines Secp256k1Native as a top-level module. Field, scalar, and point
 * methods are added by the registration helpers below.
 */
void Init_secp256k1_native(void) {
    rb_mSecp256k1Native = rb_define_module("Secp256k1Native");

    register_field_methods(rb_mSecp256k1Native);
    register_scalar_methods(rb_mSecp256k1Native);
    register_jacobian_methods(rb_mSecp256k1Native);
}
