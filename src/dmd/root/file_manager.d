/**
 * File manager to be able to both load source files from memory and from disk.
 *
 * Copyright:   Copyright (C) 1999-2020 by The D Language Foundation, All Rights Reserved
 * Authors:     $(LINK2 http://www.digitalmars.com, Walter Bright)
 * License:     $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 * Source:      $(LINK2 https://github.com/dlang/dmd/blob/master/src/dmd/filecache.d, filecache.d)
 * Documentation:  https://dlang.org/phobos/dmd_filecache.html
 * Coverage:    https://codecov.io/gh/dlang/dmd/src/master/src/dmd/filecache.d
 */
module dmd.root.file_manager;

struct FileManager
{
    import dmd.root.stringtable : StringTable;
    import dmd.root.filename : FileName;

    private static immutable packageFiles = ["package.di", "package.d"];

    private StringTable!File files;
    private const string[] fileExtensions;
    private const string[] importPaths;

nothrow:

    this(string[] fileExtensions, FileName[] importPaths)
    {
        this.fileExtensions = fileExtensions;
        this.importPaths = importPaths;
    }

    /**
     * Looks up the given filename in memory.
     *
     * Returns: the loaded source file if it was found in memory,
     *      otherwise `null`
     */
    File* opIndex(FileName filename)
    {
        return files.lookup(filename.toString);
    }

    /**
     * Loads the source file with the given filename either from memory or disk.
     *
     * It will look for the following cases:
     * * The actual given filename
     * * The filename with the `.d` or `.di` extension added
     * * The filename as a directory with a containing `package.d` or
     *      `package.di` file
     *
     * Returns: the loaded source file if it was found in memory or on disk,
     *      otherwise `null`
     */
    File* loadSourceFile(FileName filename)
    {
        import std.algorithm : map;
        import std.array : array;
        import std.range : only;

        const name = filename.toString;

        auto packagePaths = packageFiles
            .map!(pack => FileName.combine(name, pack));

        fileExtensions
            .map!(ext => FileName.forceExt(name, ext))
            .chain(packagePaths)
            .array;
    }

    private File* lookupInCache(Range)(Range range)
    {

    }
}
