module lexer.diagnostic_reporter;

import core.stdc.stdarg;

import dmd.diagnostic : CollectingDiagnosticHandler, DiagnosticHandler, Severity;
import dmd.globals : Loc, global, DiagnosticReporting;

import support : afterEach, NoopDiagnosticReporter;

@afterEach deinitializeFrontend()
{
    import dmd.frontend : deinitializeDMD;
    deinitializeDMD();
}

@("errors: unterminated /* */ comment")
unittest
{
    static struct ErrorCountingDiagnosticHandler
    {
        int errorCount;

        void handleDiagnostic(
            const ref Loc loc, Severity severity,
            scope const char* messageFormat,
            va_list args,
            bool isSupplemental = false
        ) pure nothrow
        {
            if (severity == Severity.error)
                errorCount++;
        }
    }

    auto handler = ErrorCountingDiagnosticHandler();
    lexUntilEndOfFile("/*", &handler.handleDiagnostic);

    assert(handler.errorCount == 1);
}

@("warnings: C preprocessor directive")
unittest
{
    static struct WarningCountingDiagnosticHandler
    {
        int warningCount;

        void handleDiagnostic(
            const ref Loc loc, Severity severity,
            scope const char* messageFormat,
            va_list args,
            bool isSupplemental = false
        ) pure nothrow
        {
            if (severity == Severity.warning)
                warningCount++;
        }
    }

    global.params.warnings = DiagnosticReporting.inform;
    auto handler = WarningCountingDiagnosticHandler();
    lexUntilEndOfFile(`#foo`, &handler.handleDiagnostic);

    assert(handler.warningCount == 1);
}

private void lexUntilEndOfFile(string code, DiagnosticHandler diagnosticHandler)
{
    import dmd.lexer : Lexer;
    import dmd.tokens : TOK;

    scope lexer = new Lexer("test", code.ptr, 0, code.length, 0, 0, diagnosticHandler);
    lexer.nextToken;

    while (lexer.nextToken != TOK.endOfFile) {}
}
