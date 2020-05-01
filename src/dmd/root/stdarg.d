/**
 * Copy of core.stdc.stdarg;
 *
 * Copyright: Copyright (C) 1999-2020 by The D Language Foundation, All Rights Reserved
 * Authors:   Walter Bright, http://www.digitalmars.com
 * License:   $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 * Source:    $(LINK2 https://github.com/dlang/dmd/blob/master/src/dmd/root/speller.d, root/_speller.d)
 * Documentation:  https://dlang.org/phobos/dmd_root_speller.html
 * Coverage:    https://codecov.io/gh/dlang/dmd/src/master/src/dmd/root/speller.d
 */

module dmd.root.stdarg;

public import core.stdc.stdarg;

@system:
//@nogc:    // Not yet, need to make TypeInfo's member functions @nogc first
nothrow:
pure:

void va_end(va_list ap)
{
}

version (X86)
{

    void va_copy(out va_list dest, va_list src)
    {
        dest = src;
    }
}
else version (Windows)
{
    ///
    void va_copy(out va_list dest, va_list src)
    {
        dest = src;
    }
}
else version (X86_64)
{
    import core.stdc.stdlib : alloca;

    ///
    void va_copy(out va_list dest, va_list src, void* storage = alloca(__va_list_tag.sizeof))
    {
        // Instead of copying the pointers, and aliasing the source va_list,
        // the default argument alloca will allocate storage in the caller's
        // stack frame.  This is still not correct (it should be allocated in
        // the place where the va_list variable is declared) but most of the
        // time the caller's stack frame _is_ the place where the va_list is
        // allocated, so in most cases this will now work.
        dest = cast(va_list)storage;
        *dest = *src;
    }
}
else
    static assert(false, "Unsupported platform");
