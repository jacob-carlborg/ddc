#!/usr/bin/env dub
/+dub.sdl:
dependency "dmd" path="../.."
+/
void main()
{
    import dmd.diagnostic : DefaultDiagnosticHandler;
    import dmd.globals;
    import dmd.lexer;
    import dmd.tokens;

    immutable expected = [
        TOK.void_,
        TOK.identifier,
        TOK.leftParentheses,
        TOK.rightParentheses,
        TOK.leftCurly,
        TOK.rightCurly
    ];

    immutable sourceCode = "void test() {} // foobar";
    auto diagnosticHandler = DefaultDiagnosticHandler();
    scope lexer = new Lexer("test", sourceCode.ptr, 0, sourceCode.length, 0, 0, diagnosticHandler.diagnosticHandler);
    lexer.nextToken;
    diagnosticHandler.report();

    TOK[] result;

    do
    {
        result ~= lexer.token.value;
        diagnosticHandler.report();
    } while (lexer.nextToken != TOK.endOfFile);
    diagnosticHandler.report();

    assert(result == expected);
}
