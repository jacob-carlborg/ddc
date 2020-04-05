/**
 * Tests for Token quality.
 *
 * Most of the tests in this module are generated based on a description.
 */
module lexer.location_offset;

import dmd.lexer : Lexer;
import dmd.diagnostic : CollectingDiagnosticHandler;

import support : afterEach;

@afterEach deinitializeFrontend()
{
    import dmd.frontend : deinitializeDMD;
    deinitializeDMD();
}

@("identifier after comment")
unittest
{
    enum code = "/* comment */ token";

    auto diagnosticHandler = CollectingDiagnosticHandler();
    scope lexer = new Lexer("test.d", code.ptr, 0, code.length, 0, 0,
        &diagnosticHandler.handleDiagnostic);

    lexer.nextToken;

    assert(diagnosticHandler.diagnostics.empty,
        '\n' ~ diagnosticHandler.diagnostics.toString);

    const offset = lexer.token.loc.offset;
    assert(offset == 14, offset.toString(code));
}

/**
 * Contains the necessary information to generate a unit test block.
 *
 * The generated test will test a single token by:
 *
 * * Setting a lexer
 * * Lex the first two tokens
 * * Verify the offset of the second token
 *
 * Example of a generate unit test block:
 * ---
 * @("left parentheses, (")
 * unittest
 * {
 *      assert(isFirstTokenEqual("(", ")", false));
 * }
 * ---
 */
immutable struct Test
{
    /**
     * The description of the unit test.
     *
     * This will go into the UDA attached to the `unittest` block.
     */
    string description_;

    /**
     * The code to lex.
     *
     * Optional. If the code is not provided the description will be used.
     * Useful when the description and the code is exactly the same, i.e. for
     * keywords.
     */
    string code_ = null;

    /**
     * An example of the token that is tested.
     *
     * Optional. If the example is not provided, `code` will be used.
     */
    string tokenExample = null;

    /**
     * Allow failed diagnostics.
     *
     * If this is `false` and the lexer reports a diagnostic, an assertion is
     * triggered.
     */
    bool allowFailedDiagnostics = false;

    /// Returns: the code for the first lexer
    string code()
    {
        return code_ ? code_ : description_;
    }

    /// Returns: the description
    string description()
    {
        const example = tokenExample ? tokenExample : code;

        if (example == description_)
            return example;
        else
            return description_ ~ ", " ~ example;
    }
}

enum Test hexadecimalStringLiteral = {
    description_: "hexadecimal string literal",
    code_: `x"61"`,
    // allow failed diagnostics because this is now an error. But it's still
    // recognized by the lexer and the lexer will create a token when this error
    // occurs.
    allowFailedDiagnostics: true
};

/// Tests for all different kinds of tokens.
enum tests = [
    Test("left parentheses", "("),
    Test("right parentheses", ")"),
    Test("left square bracket", "["),
    Test("right square bracket", "]"),
    Test("left curly brace", "{"),
    Test("right curly brace", "{"),
    Test("colon", ":"),
    Test("negate", "!"),
    Test("semicolon", ";"),
    Test("triple dot", "..."),
    Test("end of file", "\u001A"),
    Test("cast"),
    Test("null"),
    Test("assert"),
    Test("true"),
    Test("false"),
    Test("throw"),
    Test("new"),
    Test("delete"),
    Test("new"),
    Test("slice", ".."),
    Test("version"),
    Test("module"),
    Test("dollar", "$"),
    Test("template"),
    Test("typeof"),
    Test("pragma"),
    Test("typeid"),

    Test("less than", "<"),
    Test("greater then", ">"),
    Test("less then or equal", "<="),
    Test("greater then or equal", ">="),
    Test("equal", "=="),
    Test("not equal", "!="),
    Test("identify", "is"),
    Test("not identify", "!is"),
    Test("left shift", "<<"),
    Test("right shift", ">>"),
    Test("left shift assign", "<<="),
    Test("right shift assign", ">>="),
    Test("unsigned right shift", ">>>"),
    Test("unsigned right shift assign", ">>>="),
    Test("concatenate assign", "~="),
    Test("plus", "+"),
    Test("minus", "-"),
    Test("plus assign", "+="),
    Test("minus assign", "-="),
    Test("multiply", "*"),
    Test("divide", "/"),
    Test("modulo", "%"),
    Test("multiply assign", "*="),
    Test("divide assign", "/="),
    Test("modulo assign", "%="),
    Test("and", "&"),
    Test("or", "|"),
    Test("xor", "^"),
    Test("and assign", "&="),
    Test("or assign", "|="),
    Test("xor assign", "^="),
    Test("assign", "="),
    Test("not", "!"),
    Test("tilde", "~"),
    Test("plus plus", "++"),
    Test("minus minus", "--"),
    Test("dot", "."),
    Test("comma", ","),
    Test("question mark", "?"),
    Test("and and", "&&"),
    Test("or or", "||"),

    Test("32 bit integer literal", "0"),
    Test("32 bit unsigned integer literal", "0U"),
    Test("64 bit integer literal", "0L"),
    Test("64 bit unsigned integer literal", "0UL"),
    Test("32 bit floating point literal", "0.0f"),
    Test("64 bit floating point literal", "0.0"),
    Test("80 bit floating point literal", "0.0L"),
    Test("32 bit imaginary floating point literal", "0.0fi"),
    Test("64 bit imaginary floating point literal", "0.0i"),
    Test("80 bit imaginary floating point literal", "0.0Li"),

    Test("character literal", "'a'"),
    Test("wide character literal", "'ö'"),
    Test("double wide character literal", "'🍺'"),

    Test("identifier", "foo"),
    Test("string literal", `"foo"`),
    hexadecimalStringLiteral,
    Test("this"),
    Test("super"),

    Test("void"),
    Test("byte"),
    Test("ubyte"),
    Test("short"),
    Test("ushort"),
    Test("int"),
    Test("uint"),
    Test("long"),
    Test("ulong"),
    Test("cent"),
    Test("ucent"),
    Test("float"),
    Test("double"),
    Test("real"),
    Test("ifloat"),
    Test("idouble"),
    Test("ireal"),
    Test("cfloat"),
    Test("cdouble"),
    Test("creal"),
    Test("char"),
    Test("wchar"),
    Test("dchar"),
    Test("bool"),

    Test("struct"),
    Test("class"),
    Test("interface"),
    Test("union"),
    Test("enum"),
    Test("import"),
    Test("alias"),
    Test("override"),
    Test("delegate"),
    Test("function"),
    Test("mixin"),
    Test("align"),
    Test("extern"),
    Test("private"),
    Test("protected"),
    Test("public"),
    Test("export"),
    Test("static"),
    Test("final"),
    Test("const"),
    Test("abstract"),
    Test("debug"),
    Test("deprecated"),
    Test("in"),
    Test("out"),
    Test("inout"),
    Test("lazy"),
    Test("auto"),
    Test("package"),
    Test("immutable"),

    Test("if"),
    Test("else"),
    Test("while"),
    Test("for"),
    Test("do"),
    Test("switch"),
    Test("case"),
    Test("default"),
    Test("break"),
    Test("continue"),
    Test("with"),
    Test("synchronized"),
    Test("return"),
    Test("goto"),
    Test("try"),
    Test("catch"),
    Test("finally"),
    Test("asm"),
    Test("foreach"),
    Test("foreach_reverse"),
    Test("scope"),

    Test("invariant"),

    Test("unittest"),

    Test("__argTypes"),
    Test("ref"),
    Test("macro"),

    Test("__parameters"),
    Test("__traits"),
    Test("__overloadset"),
    Test("pure"),
    Test("nothrow"),
    Test("__gshared"),

    Test("__LINE__"),
    Test("__FILE__"),
    Test("__FILE_FULL_PATH__"),
    Test("__MODULE__"),
    Test("__FUNCTION__"),
    Test("__PRETTY_FUNCTION__"),

    Test("shared"),
    Test("at sign", "@"),
    Test("power", "^^"),
    Test("power assign", "^^="),
    Test("fat arrow", "=>"),
    Test("__vector"),
    Test("pound", "#"),
];

static foreach (test; tests)
{
    @(test.description)
    unittest
    {
        const newCode = "first_token " ~ test.code;

        auto diagnosticHandler = CollectingDiagnosticHandler();
        scope lexer = new Lexer("test.d", newCode.ptr, 0, newCode.length, 0, 0,
            &diagnosticHandler.handleDiagnostic);

        lexer.nextToken;
        lexer.nextToken;

        if (!test.allowFailedDiagnostics)
        {
            assert(diagnosticHandler.diagnostics.empty,
                '\n' ~ diagnosticHandler.diagnostics.toString);
        }

        const offset = lexer.token.loc.offset;
        assert(offset == 12, offset.toString(newCode));
    }
}

private string toString(uint offset, string code)
{
    import std.format : format;
    return format!`%s: %s`(offset, code[offset .. $]);
}
