#include "natalie.hpp"

using namespace Natalie;

/*NAT_DECLARATIONS*/

extern "C" Env *build_top_env() {
    auto env = Natalie::build_top_env();
    Value self = GlobalEnv::the()->main_obj();
    (void)self; // don't warn about unused var
    /*NAT_OBJ_INIT*/
    return env;
}

extern "C" Object *EVAL(Env *env) {
    /*NAT_EVAL_INIT*/

    Value self = GlobalEnv::the()->main_obj();
    (void)self; // don't warn about unused var
    volatile bool run_exit_handlers = true;

    // kinda hacky, but needed for top-level begin/rescue
    size_t argc = 0;
    Value *args = nullptr;
    Block *block = nullptr;

    try {
        /*NAT_EVAL_BODY*/
        run_exit_handlers = false;
        run_at_exit_handlers(env);
        return NilObject::the(); // just in case there's no return value
    } catch (ExceptionObject *exception) {
        handle_top_level_exception(env, exception, run_exit_handlers);
        return nullptr;
    }
}

Value _main(int argc, char *argv[]) {
    Env *env = ::build_top_env();
    FiberObject::build_main_fiber(Heap::the().start_of_stack());

#ifndef NAT_GC_DISABLE
    Heap::the().gc_enable();
#endif

    assert(argc > 0);
    Value exe = new StringObject { argv[0] };
    env->global_set(SymbolObject::intern("$exe"), exe);

    ArrayObject *ARGV = new ArrayObject {};
    GlobalEnv::the()->Object()->const_set(SymbolObject::intern("ARGV"), ARGV);
    for (int i = 1; i < argc; i++) {
        ARGV->push(new StringObject { argv[i] });
    }

    return EVAL(env);
}

int main(int argc, char *argv[]) {
    Heap::the().set_start_of_stack(&argv);
#ifdef NAT_GC_COLLECT_ALL_AT_EXIT
    Heap::the().set_collect_all_at_exit(true);
#endif
    setvbuf(stdout, nullptr, _IOLBF, 1024);
    auto return_code = _main(argc, argv) ? 0 : 1;
    clean_up_and_exit(return_code);
}
