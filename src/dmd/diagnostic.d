/**
 * Compiler implementation of the
 * $(LINK2 http://www.dlang.org, D programming language).
 *
 * Copyright:   Copyright (C) 1999-2020 by The D Language Foundation, All Rights Reserved
 * Authors:     $(LINK2 http://www.digitalmars.com, Walter Bright)
 * License:     $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 * Source:      $(LINK2 https://github.com/dlang/dmd/blob/master/src/dmd/errors.d, _errors.d)
 * Documentation:  https://dlang.org/phobos/dmd_errors.html
 * Coverage:    https://codecov.io/gh/dlang/dmd/src/master/src/dmd/errors.d
 */

module dmd.diagnostic;

import core.stdc.stdarg : va_list;

import dmd.globals : Loc;

alias DiagnosticHandler = void delegate(const ref Loc loc,
    Severity severity, scope const char* messageFormat,
    va_list args, bool isSupplemental = false) pure nothrow;

/// The severity level of a diagnostic.
enum Severity
{
    /// An error occurred.
    error,

     /// A warning occurred.
    warning,

     /// A deprecation occurred.
    deprecation,
}

struct Diagnostic
{
    /// The location of where the diagnostic occurred.
    const Loc location;

    /// The message.
    const string message;

    /// The severity of the diagnostic.
    const Severity severity;

    /// The supplemental diagnostics belonging to this diagnostic.
    private const(Diagnostic)[] _supplementalDiagnostics;

    /// Returns: a textual representation of the diagnostic set
    string toString() const pure
    {
        import std.format : format;
        import std.string : fromStringz;

        return format!"%s:%s:%s: %s: %s%s%(%s\n%)"(
            location.filename.fromStringz,
            location.linnum,
            location.charnum,
            severity,
            message,
            supplementalDiagnostics.length > 0 ? "\n" : "",
            supplementalDiagnostics
        );
    }

pure nothrow @safe:

    /// Returns: the supplemental diagnostics attached to this diagnostic.
    const(Diagnostic[]) supplementalDiagnostics() const @nogc
    {
        return _supplementalDiagnostics;
    }

    /**
     * Adds a supplemental diagnostic to this diagnostic.
     *
     * Params:
     *  diagnostic = the supplemental diagnostic to add
     */
    private void addSupplementalDiagnostic(Diagnostic diagnostic)
    in(diagnostic.severity == severity)
    {
        _supplementalDiagnostics ~= diagnostic;
    }
}

/// Stores a set of diagnostics.
struct DiagnosticSet
{
    private Diagnostic[] _diagnostics;

pure:

    /// Returns: a textual representation of the diagnostic set
    string toString() const
    {
        import std.format : format;

        return format!"%(%s\n%)"(_diagnostics);
    }

@safe nothrow:

    /**
     * Adds the given diagnostic to the set of diagnostics.
     *
     * Params:
     *  diagnostic = the diagnostic to add
     */
    DiagnosticSet opOpAssign(string op)(Diagnostic diagnostic)
    if (op == "~")
    {
        _diagnostics ~= diagnostic;
        return this;
    }

    /// ditto
    void add(Diagnostic diagnostic)
    {
        _diagnostics ~= diagnostic;
    }

    /**
     * Adds the given supplemental diagnostic to the last added diagnostic.
     *
     * Params:
     *  diagnostic = the supplemental diagnostic to add
     */
    void addSupplemental(Diagnostic diagnostic)
    {
        _diagnostics[$ - 1].addSupplementalDiagnostic(diagnostic);
    }

@nogc:

    /// Returns: the diagnostic at the front of the range.
    const(Diagnostic) front() const
    {
        return _diagnostics[0];
    }

    /// Advances the range forward.
    void popFront()
    {
        _diagnostics = _diagnostics[1 .. $];
    }

    /// Returns: `true` if no diagnostics are stored.
    bool empty() const
    {
        return _diagnostics.length == 0;
    }

    /// Returns: the number of diagnostics stored.
    size_t length() const
    {
        return _diagnostics.length;
    }

    /**
     * Returns the diagnostic stored at the given index.
     *
     * Params:
     *  index = the index of the diagnostic to return
     *
     * Returns: the diagnostic
     */
    const(Diagnostic) opIndex(size_t index) const
    {
        return _diagnostics[index];
    }
}

DiagnosticHandler suppressingDiagnosticHandler = (
    const ref Loc loc,
    Severity severity,
    scope const char* messageFormat,
    va_list args,
    bool isSupplemental = false
) pure nothrow {};

struct CollectingDiagnosticHandler
{
    private DiagnosticSet diagnostics_;

    DiagnosticSet diagnostics() pure nothrow @safe @nogc
    {
        return diagnostics_;
    }

    void handleDiagnostic(
        const ref Loc loc, Severity severity,
        scope const char* messageFormat,
        va_list args,
        bool isSupplemental = false
    ) pure nothrow
    {
        import dmd.root.outbuffer : OutBuffer;

        auto buffer = OutBuffer();
        buffer.vprintf(messageFormat, args);
        auto diagnostic = Diagnostic(loc, buffer.extractSlice, severity);

        if (isSupplemental)
            diagnostics_.addSupplemental(diagnostic);
        else
            diagnostics_ ~= diagnostic;
    }
}

struct DefaultDiagnosticReporter
{
    void report(DiagnosticSet diagnostics) nothrow
    {
        alias ReportingFunction =
            extern (C++) void function(
                ref const(Loc) loc, const(char)* format, ...
            ) nothrow;

        static ReportingFunction getReportingFunction(Severity severity)
        {
            import dmd.errors : deprecation, error, warning;

            final switch (severity)
            {
                case Severity.error: return &error;
                case Severity.warning: return &warning;
                case Severity.deprecation: return &deprecation;
            }
        }

        static ReportingFunction getSupplementalReportingFunction(Severity severity)
        {
            import dmd.errors : deprecationSupplemental, errorSupplemental,
                warningSupplemental;

            final switch (severity)
            {
                case Severity.error: return &errorSupplemental;
                case Severity.warning: return &warningSupplemental;
                case Severity.deprecation: return &deprecationSupplemental;
            }
        }

        static void report(const ref Diagnostic diagnostic, ReportingFunction func)
        {
            with (diagnostic)
                func(location, "%.*s", cast(int) message.length, message.ptr);
        }

        foreach (const ref diagnostic; diagnostics)
        {
            const func = getReportingFunction(diagnostic.severity);
            report(diagnostic, func);

            foreach (const ref supplemental; diagnostic.supplementalDiagnostics)
            {
                const supplementalFunc =
                    getSupplementalReportingFunction(diagnostic.severity);
                report(supplemental, supplementalFunc);
            }
        }
    }
}

struct DefaultDiagnosticHandler
{
    private CollectingDiagnosticHandler handler;
    private DefaultDiagnosticReporter reporter;

    DiagnosticHandler diagnosticHandler() pure nothrow @nogc @safe return
    {
        return &handler.handleDiagnostic;
    }

    void report() nothrow
    {
        reporter.report(handler.diagnostics);
        handler.diagnostics_ = DiagnosticSet();
    }
}
