/**
 * Takes a token stream from the lexer, and parses it into an abstract syntax tree.
 *
 * Specification: $(LINK2 https://dlang.org/spec/grammar.html, D Grammar)
 *
 * Copyright:   Copyright (C) 1999-2020 by The D Language Foundation, All Rights Reserved
 * Authors:     $(LINK2 http://www.digitalmars.com, Walter Bright)
 * License:     $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost License 1.0)
 * Source:      $(LINK2 https://github.com/dlang/dmd/blob/master/src/dmd/parse.d, _parse.d)
 * Documentation:  https://dlang.org/phobos/dmd_parse.html
 * Coverage:    https://codecov.io/gh/dlang/dmd/src/master/src/dmd/parse.d
 */

module dmd.parse;

import core.stdc.stdio;
import core.stdc.string;
import dmd.globals;
import dmd.id;
import dmd.identifier;
import dmd.lexer;
import dmd.errors;
import dmd.root.filename;
import dmd.root.outbuffer;
import dmd.root.rmem;
import dmd.root.rootobject;
import dmd.root.string;
import dmd.tokens;

// How multiple declarations are parsed.
// If 1, treat as C.
// If 0, treat:
//      int *p, i;
// as:
//      int* p;
//      int* i;
private enum CDECLSYNTAX = 0;

// Support C cast syntax:
//      (type)(expression)
private enum CCASTSYNTAX = 1;

// Support postfix C array declarations, such as
//      int a[3][4];
private enum CARRAYDECL = 1;

/**********************************
 * Set operator precedence for each operator.
 *
 * Used by hdrgen
 */
immutable PREC[TOK.max_] precedence =
[
    TOK.type : PREC.expr,
    TOK.error : PREC.expr,
    TOK.objcClassReference : PREC.expr, // Objective-C class reference, same as TOK.type

    TOK.typeof_ : PREC.primary,
    TOK.mixin_ : PREC.primary,

    TOK.import_ : PREC.primary,
    TOK.dotVariable : PREC.primary,
    TOK.scope_ : PREC.primary,
    TOK.identifier : PREC.primary,
    TOK.this_ : PREC.primary,
    TOK.super_ : PREC.primary,
    TOK.int64 : PREC.primary,
    TOK.float64 : PREC.primary,
    TOK.complex80 : PREC.primary,
    TOK.null_ : PREC.primary,
    TOK.string_ : PREC.primary,
    TOK.arrayLiteral : PREC.primary,
    TOK.assocArrayLiteral : PREC.primary,
    TOK.classReference : PREC.primary,
    TOK.file : PREC.primary,
    TOK.fileFullPath : PREC.primary,
    TOK.line : PREC.primary,
    TOK.moduleString : PREC.primary,
    TOK.functionString : PREC.primary,
    TOK.prettyFunction : PREC.primary,
    TOK.typeid_ : PREC.primary,
    TOK.is_ : PREC.primary,
    TOK.assert_ : PREC.primary,
    TOK.halt : PREC.primary,
    TOK.template_ : PREC.primary,
    TOK.dSymbol : PREC.primary,
    TOK.function_ : PREC.primary,
    TOK.variable : PREC.primary,
    TOK.symbolOffset : PREC.primary,
    TOK.structLiteral : PREC.primary,
    TOK.arrayLength : PREC.primary,
    TOK.delegatePointer : PREC.primary,
    TOK.delegateFunctionPointer : PREC.primary,
    TOK.remove : PREC.primary,
    TOK.tuple : PREC.primary,
    TOK.traits : PREC.primary,
    TOK.default_ : PREC.primary,
    TOK.overloadSet : PREC.primary,
    TOK.void_ : PREC.primary,
    TOK.vectorArray : PREC.primary,

    // post
    TOK.dotTemplateInstance : PREC.primary,
    TOK.dotIdentifier : PREC.primary,
    TOK.dotTemplateDeclaration : PREC.primary,
    TOK.dot : PREC.primary,
    TOK.dotType : PREC.primary,
    TOK.plusPlus : PREC.primary,
    TOK.minusMinus : PREC.primary,
    TOK.prePlusPlus : PREC.primary,
    TOK.preMinusMinus : PREC.primary,
    TOK.call : PREC.primary,
    TOK.slice : PREC.primary,
    TOK.array : PREC.primary,
    TOK.index : PREC.primary,

    TOK.delegate_ : PREC.unary,
    TOK.address : PREC.unary,
    TOK.star : PREC.unary,
    TOK.negate : PREC.unary,
    TOK.uadd : PREC.unary,
    TOK.not : PREC.unary,
    TOK.tilde : PREC.unary,
    TOK.delete_ : PREC.unary,
    TOK.new_ : PREC.unary,
    TOK.newAnonymousClass : PREC.unary,
    TOK.cast_ : PREC.unary,

    TOK.vector : PREC.unary,
    TOK.pow : PREC.pow,

    TOK.mul : PREC.mul,
    TOK.div : PREC.mul,
    TOK.mod : PREC.mul,

    TOK.add : PREC.add,
    TOK.min : PREC.add,
    TOK.concatenate : PREC.add,

    TOK.leftShift : PREC.shift,
    TOK.rightShift : PREC.shift,
    TOK.unsignedRightShift : PREC.shift,

    TOK.lessThan : PREC.rel,
    TOK.lessOrEqual : PREC.rel,
    TOK.greaterThan : PREC.rel,
    TOK.greaterOrEqual : PREC.rel,
    TOK.in_ : PREC.rel,

    /* Note that we changed precedence, so that < and != have the same
     * precedence. This change is in the parser, too.
     */
    TOK.equal : PREC.rel,
    TOK.notEqual : PREC.rel,
    TOK.identity : PREC.rel,
    TOK.notIdentity : PREC.rel,

    TOK.and : PREC.and,
    TOK.xor : PREC.xor,
    TOK.or : PREC.or,

    TOK.andAnd : PREC.andand,
    TOK.orOr : PREC.oror,

    TOK.question : PREC.cond,

    TOK.assign : PREC.assign,
    TOK.construct : PREC.assign,
    TOK.blit : PREC.assign,
    TOK.addAssign : PREC.assign,
    TOK.minAssign : PREC.assign,
    TOK.concatenateAssign : PREC.assign,
    TOK.concatenateElemAssign : PREC.assign,
    TOK.concatenateDcharAssign : PREC.assign,
    TOK.mulAssign : PREC.assign,
    TOK.divAssign : PREC.assign,
    TOK.modAssign : PREC.assign,
    TOK.powAssign : PREC.assign,
    TOK.leftShiftAssign : PREC.assign,
    TOK.rightShiftAssign : PREC.assign,
    TOK.unsignedRightShiftAssign : PREC.assign,
    TOK.andAssign : PREC.assign,
    TOK.orAssign : PREC.assign,
    TOK.xorAssign : PREC.assign,

    TOK.comma : PREC.expr,
    TOK.declaration : PREC.expr,

    TOK.interval : PREC.assign,
];

enum ParseStatementFlags : int
{
    semi          = 1,        // empty ';' statements are allowed, but deprecated
    scope_        = 2,        // start a new scope
    curly         = 4,        // { } statement is required
    curlyScope    = 8,        // { } starts a new scope
    semiOk        = 0x10,     // empty ';' are really ok
}

private struct PrefixAttributes(AST)
{
    StorageClass storageClass;
    AST.Expression depmsg;
    LINK link;
    AST.Prot protection;
    bool setAlignment;
    AST.Expression ealign;
    AST.Expressions* udas;
    const(char)* comment;
}

/*****************************
 * Destructively extract storage class from pAttrs.
 */
private StorageClass getStorageClass(AST)(PrefixAttributes!(AST)* pAttrs)
{
    StorageClass stc = AST.STC.undefined_;
    if (pAttrs)
    {
        stc = pAttrs.storageClass;
        pAttrs.storageClass = AST.STC.undefined_;
    }
    return stc;
}

/**************************************
 * dump mixin expansion to file for better debugging
 */
private bool writeMixin(const(char)[] s, ref Loc loc)
{
    if (!global.params.mixinOut)
        return false;

    OutBuffer* ob = global.params.mixinOut;

    ob.writestring("// expansion at ");
    ob.writestring(loc.toChars());
    ob.writenl();

    global.params.mixinLines++;

    loc = Loc(global.params.mixinFile, global.params.mixinLines + 1, loc.charnum);

    // write by line to create consistent line endings
    size_t lastpos = 0;
    for (size_t i = 0; i < s.length; ++i)
    {
        // detect LF and CRLF
        const c = s[i];
        if (c == '\n' || (c == '\r' && i+1 < s.length && s[i+1] == '\n'))
        {
            ob.writestring(s[lastpos .. i]);
            ob.writenl();
            global.params.mixinLines++;
            if (c == '\r')
                ++i;
            lastpos = i + 1;
        }
    }

    if(lastpos < s.length)
        ob.writestring(s[lastpos .. $]);

    if (s.length == 0 || s[$-1] != '\n')
    {
        ob.writenl(); // ensure empty line after expansion
        global.params.mixinLines++;
    }
    ob.writenl();
    global.params.mixinLines++;

    return true;
}

/***********************************************************
 */
final class Parser(AST) : Lexer
{
    import dmd.diagnostic : DefaultDiagnosticHandler;

    AST.ModuleDeclaration* md;
    alias STC = AST.STC;

    private
    {
        AST.Module mod;
        LINK linkage;
        CPPMANGLE cppmangle;
        Loc endloc; // set to location of last right curly
        int inBrackets; // inside [] of array index or slice
        Loc lookingForElse; // location of lonely if looking for an else
        DefaultDiagnosticHandler diagnosticHandler;
    }

    /*********************
     * Use this constructor for string mixins.
     * Input:
     *      loc     location in source file of mixin
     */
    extern (D) this(const ref Loc loc, AST.Module _module, const(char)[] input, bool doDocComment)
    {
        super(_module ? _module.srcfile.toChars() : null, input.ptr, 0, input.length, doDocComment, false, diagnosticHandler.diagnosticHandler);

        //printf("Parser::Parser()\n");
        scanloc = loc;

        if (!writeMixin(input, scanloc) && loc.filename)
        {
            /* Create a pseudo-filename for the mixin string, as it may not even exist
             * in the source file.
             */
            char* filename = cast(char*)mem.xmalloc(strlen(loc.filename) + 7 + (loc.linnum).sizeof * 3 + 1);
            sprintf(filename, "%s-mixin-%d", loc.filename, cast(int)loc.linnum);
            scanloc.filename = filename;
        }

        mod = _module;
        linkage = LINK.d;
        //nextToken();              // start up the scanner
    }

    extern (D) this(AST.Module _module, const(char)[] input, bool doDocComment)
    {
        super(_module ? _module.srcfile.toChars() : null, input.ptr, 0, input.length, doDocComment, false, diagnosticHandler.diagnosticHandler);

        //printf("Parser::Parser()\n");
        mod = _module;
        linkage = LINK.d;
        //nextToken();              // start up the scanner
    }

    final override TOK nextToken()
    {
        const result = super.nextToken();
        diagnosticHandler.report();

        return result;
    }

    void reportDiagnostics()
    {
        diagnosticHandler.report();
    }

    AST.Dsymbols* parseModule()
    {
        const comment = token.blockComment;
        bool isdeprecated = false;
        AST.Expression msg = null;
        AST.Expressions* udas = null;
        AST.Dsymbols* decldefs;
        AST.Dsymbol lastDecl = mod; // for attaching ddoc unittests to module decl

        Token* tk;
        if (skipAttributes(&token, &tk) && tk.value == TOK.module_)
        {
            while (token.value != TOK.module_)
            {
                switch (token.value)
                {
                case TOK.deprecated_:
                    {
                        // deprecated (...) module ...
                        if (isdeprecated)
                            error("there is only one deprecation attribute allowed for module declaration");
                        isdeprecated = true;
                        nextToken();
                        if (token.value == TOK.leftParentheses)
                        {
                            check(TOK.leftParentheses);
                            msg = parseAssignExp();
                            check(TOK.rightParentheses);
                        }
                        break;
                    }
                case TOK.at:
                    {
                        AST.Expressions* exps = null;
                        const stc = parseAttribute(&exps);
                        if (stc & atAttrGroup)
                        {
                            error("`@%s` attribute for module declaration is not supported", token.toChars());
                        }
                        else
                        {
                            udas = AST.UserAttributeDeclaration.concat(udas, exps);
                        }
                        if (stc)
                            nextToken();
                        break;
                    }
                default:
                    {
                        error("`module` expected instead of `%s`", token.toChars());
                        nextToken();
                        break;
                    }
                }
            }
        }

        if (udas)
        {
            auto a = new AST.Dsymbols();
            auto udad = new AST.UserAttributeDeclaration(udas, a);
            mod.userAttribDecl = udad;
        }

        // ModuleDeclation leads off
        if (token.value == TOK.module_)
        {
            const loc = token.loc;

            nextToken();
            if (token.value != TOK.identifier)
            {
                error("identifier expected following `module`");
                goto Lerr;
            }

            AST.Identifiers* a = null;
            Identifier id = token.ident;

            while (nextToken() == TOK.dot)
            {
                if (!a)
                    a = new AST.Identifiers();
                a.push(id);
                nextToken();
                if (token.value != TOK.identifier)
                {
                    error("identifier expected following `package`");
                    goto Lerr;
                }
                id = token.ident;
            }

            md = new AST.ModuleDeclaration(loc, a, id, msg, isdeprecated);

            if (token.value != TOK.semicolon)
                error("`;` expected following module declaration instead of `%s`", token.toChars());
            nextToken();
            addComment(mod, comment);
        }

        decldefs = parseDeclDefs(0, &lastDecl);
        if (token.value != TOK.endOfFile)
        {
            error(token.loc, "unrecognized declaration");
            goto Lerr;
        }
        return decldefs;

    Lerr:
        while (token.value != TOK.semicolon && token.value != TOK.endOfFile)
            nextToken();
        nextToken();
        return new AST.Dsymbols();
    }

    /**
     * Parses a `deprecated` declaration
     *
     * Params:
     *   msg = Deprecated message, if any.
     *         Used to support overriding a deprecated storage class with
     *         a deprecated declaration with a message, but to error
     *         if both declaration have a message.
     *
     * Returns:
     *   Whether the deprecated declaration has a message
     */
    private bool parseDeprecatedAttribute(ref AST.Expression msg)
    {
        if (peekNext() != TOK.leftParentheses)
            return false;

        nextToken();
        check(TOK.leftParentheses);
        AST.Expression e = parseAssignExp();
        check(TOK.rightParentheses);
        if (msg)
        {
            error("conflicting storage class `deprecated(%s)` and `deprecated(%s)`", msg.toChars(), e.toChars());
        }
        msg = e;
        return true;
    }

    AST.Dsymbols* parseDeclDefs(int once, AST.Dsymbol* pLastDecl = null, PrefixAttributes!AST* pAttrs = null)
    {
        AST.Dsymbol lastDecl = null; // used to link unittest to its previous declaration
        if (!pLastDecl)
            pLastDecl = &lastDecl;

        const linksave = linkage; // save global state

        //printf("Parser::parseDeclDefs()\n");
        auto decldefs = new AST.Dsymbols();
        do
        {
            // parse result
            AST.Dsymbol s = null;
            AST.Dsymbols* a = null;

            PrefixAttributes!AST attrs;
            if (!once || !pAttrs)
            {
                pAttrs = &attrs;
                pAttrs.comment = token.blockComment.ptr;
            }
            AST.Prot.Kind prot;
            StorageClass stc;
            AST.Condition condition;

            linkage = linksave;

            switch (token.value)
            {
            case TOK.enum_:
                {
                    /* Determine if this is a manifest constant declaration,
                     * or a conventional enum.
                     */
                    const tv = peekNext();
                    if (tv == TOK.leftCurly || tv == TOK.colon)
                        s = parseEnum();
                    else if (tv != TOK.identifier)
                        goto Ldeclaration;
                    else
                    {
                        const nextv = peekNext2();
                        if (nextv == TOK.leftCurly || nextv == TOK.colon || nextv == TOK.semicolon)
                            s = parseEnum();
                        else
                            goto Ldeclaration;
                    }
                    break;
                }
            case TOK.import_:
                a = parseImport();
                // keep pLastDecl
                break;

            case TOK.template_:
                s = cast(AST.Dsymbol)parseTemplateDeclaration();
                break;

            case TOK.mixin_:
                {
                    const loc = token.loc;
                    switch (peekNext())
                    {
                    case TOK.leftParentheses:
                        {
                            // mixin(string)
                            nextToken();
                            auto exps = parseArguments();
                            check(TOK.semicolon);
                            s = new AST.CompileDeclaration(loc, exps);
                            break;
                        }
                    case TOK.template_:
                        // mixin template
                        nextToken();
                        s = cast(AST.Dsymbol)parseTemplateDeclaration(true);
                        break;

                    default:
                        s = parseMixin();
                        break;
                    }
                    break;
                }
            case TOK.wchar_:
            case TOK.dchar_:
            case TOK.bool_:
            case TOK.char_:
            case TOK.int8:
            case TOK.uns8:
            case TOK.int16:
            case TOK.uns16:
            case TOK.int32:
            case TOK.uns32:
            case TOK.int64:
            case TOK.uns64:
            case TOK.int128:
            case TOK.uns128:
            case TOK.float32:
            case TOK.float64:
            case TOK.float80:
            case TOK.imaginary32:
            case TOK.imaginary64:
            case TOK.imaginary80:
            case TOK.complex32:
            case TOK.complex64:
            case TOK.complex80:
            case TOK.void_:
            case TOK.alias_:
            case TOK.identifier:
            case TOK.super_:
            case TOK.typeof_:
            case TOK.dot:
            case TOK.vector:
            case TOK.struct_:
            case TOK.union_:
            case TOK.class_:
            case TOK.interface_:
            case TOK.traits:
            Ldeclaration:
                a = parseDeclarations(false, pAttrs, pAttrs.comment);
                if (a && a.dim)
                    *pLastDecl = (*a)[a.dim - 1];
                break;

            case TOK.this_:
                if (peekNext() == TOK.dot)
                    goto Ldeclaration;
                s = parseCtor(pAttrs);
                break;

            case TOK.tilde:
                s = parseDtor(pAttrs);
                break;

            case TOK.invariant_:
                const tv = peekNext();
                if (tv == TOK.leftParentheses || tv == TOK.leftCurly)
                {
                    // invariant { statements... }
                    // invariant() { statements... }
                    // invariant (expression);
                    s = parseInvariant(pAttrs);
                    break;
                }
                error("invariant body expected, not `%s`", token.toChars());
                goto Lerror;

            case TOK.unittest_:
                if (global.params.useUnitTests || global.params.doDocComments || global.params.doHdrGeneration)
                {
                    s = parseUnitTest(pAttrs);
                    if (*pLastDecl)
                        (*pLastDecl).ddocUnittest = cast(AST.UnitTestDeclaration)s;
                }
                else
                {
                    // Skip over unittest block by counting { }
                    Loc loc = token.loc;
                    int braces = 0;
                    while (1)
                    {
                        nextToken();
                        switch (token.value)
                        {
                        case TOK.leftCurly:
                            ++braces;
                            continue;

                        case TOK.rightCurly:
                            if (--braces)
                                continue;
                            nextToken();
                            break;

                        case TOK.endOfFile:
                            /* { */
                            error(loc, "closing `}` of unittest not found before end of file");
                            goto Lerror;

                        default:
                            continue;
                        }
                        break;
                    }
                    // Workaround 14894. Add an empty unittest declaration to keep
                    // the number of symbols in this scope independent of -unittest.
                    s = new AST.UnitTestDeclaration(loc, token.loc, STC.undefined_, null);
                }
                break;

            case TOK.new_:
                s = parseNew(pAttrs);
                break;

            case TOK.colon:
            case TOK.leftCurly:
                error("declaration expected, not `%s`", token.toChars());
                goto Lerror;

            case TOK.rightCurly:
            case TOK.endOfFile:
                if (once)
                    error("declaration expected, not `%s`", token.toChars());
                return decldefs;

            case TOK.static_:
                {
                    const next = peekNext();
                    if (next == TOK.this_)
                        s = parseStaticCtor(pAttrs);
                    else if (next == TOK.tilde)
                        s = parseStaticDtor(pAttrs);
                    else if (next == TOK.assert_)
                        s = parseStaticAssert();
                    else if (next == TOK.if_)
                    {
                        condition = parseStaticIfCondition();
                        AST.Dsymbols* athen;
                        if (token.value == TOK.colon)
                            athen = parseBlock(pLastDecl);
                        else
                        {
                            const lookingForElseSave = lookingForElse;
                            lookingForElse = token.loc;
                            athen = parseBlock(pLastDecl);
                            lookingForElse = lookingForElseSave;
                        }
                        AST.Dsymbols* aelse = null;
                        if (token.value == TOK.else_)
                        {
                            const elseloc = token.loc;
                            nextToken();
                            aelse = parseBlock(pLastDecl);
                            checkDanglingElse(elseloc);
                        }
                        s = new AST.StaticIfDeclaration(condition, athen, aelse);
                    }
                    else if (next == TOK.import_)
                    {
                        a = parseImport();
                        // keep pLastDecl
                    }
                    else if (next == TOK.foreach_ || next == TOK.foreach_reverse_)
                    {
                        s = parseForeach!(true,true)(token.loc, pLastDecl);
                    }
                    else
                    {
                        stc = STC.static_;
                        goto Lstc;
                    }
                    break;
                }
            case TOK.const_:
                if (peekNext() == TOK.leftParentheses)
                    goto Ldeclaration;
                stc = STC.const_;
                goto Lstc;

            case TOK.immutable_:
                if (peekNext() == TOK.leftParentheses)
                    goto Ldeclaration;
                stc = STC.immutable_;
                goto Lstc;

            case TOK.shared_:
                {
                    const next = peekNext();
                    if (next == TOK.leftParentheses)
                        goto Ldeclaration;
                    if (next == TOK.static_)
                    {
                        TOK next2 = peekNext2();
                        if (next2 == TOK.this_)
                        {
                            s = parseSharedStaticCtor(pAttrs);
                            break;
                        }
                        if (next2 == TOK.tilde)
                        {
                            s = parseSharedStaticDtor(pAttrs);
                            break;
                        }
                    }
                    stc = STC.shared_;
                    goto Lstc;
                }
            case TOK.inout_:
                if (peekNext() == TOK.leftParentheses)
                    goto Ldeclaration;
                stc = STC.wild;
                goto Lstc;

            case TOK.final_:
                stc = STC.final_;
                goto Lstc;

            case TOK.auto_:
                stc = STC.auto_;
                goto Lstc;

            case TOK.scope_:
                stc = STC.scope_;
                goto Lstc;

            case TOK.override_:
                stc = STC.override_;
                goto Lstc;

            case TOK.abstract_:
                stc = STC.abstract_;
                goto Lstc;

            case TOK.synchronized_:
                stc = STC.synchronized_;
                goto Lstc;

            case TOK.nothrow_:
                stc = STC.nothrow_;
                goto Lstc;

            case TOK.pure_:
                stc = STC.pure_;
                goto Lstc;

            case TOK.ref_:
                stc = STC.ref_;
                goto Lstc;

            case TOK.gshared:
                stc = STC.gshared;
                goto Lstc;

            case TOK.at:
                {
                    AST.Expressions* exps = null;
                    stc = parseAttribute(&exps);
                    if (stc)
                        goto Lstc; // it's a predefined attribute
                    // no redundant/conflicting check for UDAs
                    pAttrs.udas = AST.UserAttributeDeclaration.concat(pAttrs.udas, exps);
                    goto Lautodecl;
                }
            Lstc:
                pAttrs.storageClass = appendStorageClass(pAttrs.storageClass, stc);
                nextToken();

            Lautodecl:

                /* Look for auto initializers:
                 *      storage_class identifier = initializer;
                 *      storage_class identifier(...) = initializer;
                 */
                if (token.value == TOK.identifier && hasOptionalParensThen(peek(&token), TOK.assign))
                {
                    a = parseAutoDeclarations(getStorageClass!AST(pAttrs), pAttrs.comment);
                    if (a && a.dim)
                        *pLastDecl = (*a)[a.dim - 1];
                    if (pAttrs.udas)
                    {
                        s = new AST.UserAttributeDeclaration(pAttrs.udas, a);
                        pAttrs.udas = null;
                    }
                    break;
                }

                /* Look for return type inference for template functions.
                 */
                Token* tk;
                if (token.value == TOK.identifier && skipParens(peek(&token), &tk) && skipAttributes(tk, &tk) &&
                    (tk.value == TOK.leftParentheses || tk.value == TOK.leftCurly || tk.value == TOK.in_ ||
                     tk.value == TOK.out_ || tk.value == TOK.do_ ||
                     tk.value == TOK.identifier && tk.ident == Id._body))
                {
                    version (none)
                    {
                        // This deprecation has been disabled for the time being, see PR10763
                        // @@@DEPRECATED@@@
                        // https://github.com/dlang/DIPs/blob/1f5959abe482b1f9094f6484a7d0a3ade77fc2fc/DIPs/accepted/DIP1003.md
                        // Deprecated in 2.091 - Can be removed from 2.101
                        if (tk.value == TOK.identifier && tk.ident == Id._body)
                            deprecation("Usage of the `body` keyword is deprecated. Use `do` instead.");
                    }
                    a = parseDeclarations(true, pAttrs, pAttrs.comment);
                    if (a && a.dim)
                        *pLastDecl = (*a)[a.dim - 1];
                    if (pAttrs.udas)
                    {
                        s = new AST.UserAttributeDeclaration(pAttrs.udas, a);
                        pAttrs.udas = null;
                    }
                    break;
                }

                a = parseBlock(pLastDecl, pAttrs);
                auto stc2 = getStorageClass!AST(pAttrs);
                if (stc2 != STC.undefined_)
                {
                    s = new AST.StorageClassDeclaration(stc2, a);
                }
                if (pAttrs.udas)
                {
                    if (s)
                    {
                        a = new AST.Dsymbols();
                        a.push(s);
                    }
                    s = new AST.UserAttributeDeclaration(pAttrs.udas, a);
                    pAttrs.udas = null;
                }
                break;

            case TOK.deprecated_:
                {
                    stc |= STC.deprecated_;
                    if (!parseDeprecatedAttribute(pAttrs.depmsg))
                        goto Lstc;

                    a = parseBlock(pLastDecl, pAttrs);
                    s = new AST.DeprecatedDeclaration(pAttrs.depmsg, a);
                    pAttrs.depmsg = null;
                    break;
                }
            case TOK.leftBracket:
                {
                    if (peekNext() == TOK.rightBracket)
                        error("empty attribute list is not allowed");
                    error("use `@(attributes)` instead of `[attributes]`");
                    AST.Expressions* exps = parseArguments();
                    // no redundant/conflicting check for UDAs

                    pAttrs.udas = AST.UserAttributeDeclaration.concat(pAttrs.udas, exps);
                    a = parseBlock(pLastDecl, pAttrs);
                    if (pAttrs.udas)
                    {
                        s = new AST.UserAttributeDeclaration(pAttrs.udas, a);
                        pAttrs.udas = null;
                    }
                    break;
                }
            case TOK.extern_:
                {
                    if (peekNext() != TOK.leftParentheses)
                    {
                        stc = STC.extern_;
                        goto Lstc;
                    }

                    const linkLoc = token.loc;
                    AST.Identifiers* idents = null;
                    AST.Expressions* identExps = null;
                    CPPMANGLE cppmangle;
                    bool cppMangleOnly = false;
                    const link = parseLinkage(&idents, &identExps, cppmangle, cppMangleOnly);
                    if (pAttrs.link != LINK.default_)
                    {
                        if (pAttrs.link != link)
                        {
                            error("conflicting linkage `extern (%s)` and `extern (%s)`", AST.linkageToChars(pAttrs.link), AST.linkageToChars(link));
                        }
                        else if (idents || identExps || cppmangle != CPPMANGLE.def)
                        {
                            // Allow:
                            //      extern(C++, foo) extern(C++, bar) void foo();
                            // to be equivalent with:
                            //      extern(C++, foo.bar) void foo();
                            // Allow also:
                            //      extern(C++, "ns") extern(C++, class) struct test {}
                            //      extern(C++, class) extern(C++, "ns") struct test {}
                        }
                        else
                            error("redundant linkage `extern (%s)`", AST.linkageToChars(pAttrs.link));
                    }
                    pAttrs.link = link;
                    this.linkage = link;
                    a = parseBlock(pLastDecl, pAttrs);
                    if (idents)
                    {
                        assert(link == LINK.cpp);
                        assert(idents.dim);
                        for (size_t i = idents.dim; i;)
                        {
                            Identifier id = (*idents)[--i];
                            if (s)
                            {
                                a = new AST.Dsymbols();
                                a.push(s);
                            }
                            if (cppMangleOnly)
                                s = new AST.CPPNamespaceDeclaration(id, a);
                            else
                                s = new AST.Nspace(linkLoc, id, null, a);
                        }
                        pAttrs.link = LINK.default_;
                    }
                    else if (identExps)
                    {
                        assert(link == LINK.cpp);
                        assert(identExps.dim);
                        for (size_t i = identExps.dim; i;)
                        {
                            AST.Expression exp = (*identExps)[--i];
                            if (s)
                            {
                                a = new AST.Dsymbols();
                                a.push(s);
                            }
                            if (cppMangleOnly)
                                s = new AST.CPPNamespaceDeclaration(exp, a);
                            else
                                s = new AST.Nspace(linkLoc, null, exp, a);
                        }
                        pAttrs.link = LINK.default_;
                    }
                    else if (cppmangle != CPPMANGLE.def)
                    {
                        assert(link == LINK.cpp);
                        s = new AST.CPPMangleDeclaration(cppmangle, a);
                    }
                    else if (pAttrs.link != LINK.default_)
                    {
                        s = new AST.LinkDeclaration(pAttrs.link, a);
                        pAttrs.link = LINK.default_;
                    }
                    break;
                }

            case TOK.private_:
                prot = AST.Prot.Kind.private_;
                goto Lprot;

            case TOK.package_:
                prot = AST.Prot.Kind.package_;
                goto Lprot;

            case TOK.protected_:
                prot = AST.Prot.Kind.protected_;
                goto Lprot;

            case TOK.public_:
                prot = AST.Prot.Kind.public_;
                goto Lprot;

            case TOK.export_:
                prot = AST.Prot.Kind.export_;
                goto Lprot;
            Lprot:
                {
                    if (pAttrs.protection.kind != AST.Prot.Kind.undefined)
                    {
                        if (pAttrs.protection.kind != prot)
                            error("conflicting protection attribute `%s` and `%s`", AST.protectionToChars(pAttrs.protection.kind), AST.protectionToChars(prot));
                        else
                            error("redundant protection attribute `%s`", AST.protectionToChars(prot));
                    }
                    pAttrs.protection.kind = prot;

                    nextToken();

                    // optional qualified package identifier to bind
                    // protection to
                    AST.Identifiers* pkg_prot_idents = null;
                    if (pAttrs.protection.kind == AST.Prot.Kind.package_ && token.value == TOK.leftParentheses)
                    {
                        pkg_prot_idents = parseQualifiedIdentifier("protection package");
                        if (pkg_prot_idents)
                            check(TOK.rightParentheses);
                        else
                        {
                            while (token.value != TOK.semicolon && token.value != TOK.endOfFile)
                                nextToken();
                            nextToken();
                            break;
                        }
                    }

                    const attrloc = token.loc;
                    a = parseBlock(pLastDecl, pAttrs);
                    if (pAttrs.protection.kind != AST.Prot.Kind.undefined)
                    {
                        if (pAttrs.protection.kind == AST.Prot.Kind.package_ && pkg_prot_idents)
                            s = new AST.ProtDeclaration(attrloc, pkg_prot_idents, a);
                        else
                            s = new AST.ProtDeclaration(attrloc, pAttrs.protection, a);

                        pAttrs.protection = AST.Prot(AST.Prot.Kind.undefined);
                    }
                    break;
                }
            case TOK.align_:
                {
                    const attrLoc = token.loc;

                    nextToken();

                    AST.Expression e = null; // default
                    if (token.value == TOK.leftParentheses)
                    {
                        nextToken();
                        e = parseAssignExp();
                        check(TOK.rightParentheses);
                    }

                    if (pAttrs.setAlignment)
                    {
                        if (e)
                            error("redundant alignment attribute `align(%s)`", e.toChars());
                        else
                            error("redundant alignment attribute `align`");
                    }

                    pAttrs.setAlignment = true;
                    pAttrs.ealign = e;
                    a = parseBlock(pLastDecl, pAttrs);
                    if (pAttrs.setAlignment)
                    {
                        s = new AST.AlignDeclaration(attrLoc, pAttrs.ealign, a);
                        pAttrs.setAlignment = false;
                        pAttrs.ealign = null;
                    }
                    break;
                }
            case TOK.pragma_:
                {
                    AST.Expressions* args = null;
                    const loc = token.loc;

                    nextToken();
                    check(TOK.leftParentheses);
                    if (token.value != TOK.identifier)
                    {
                        error("`pragma(identifier)` expected");
                        goto Lerror;
                    }
                    Identifier ident = token.ident;
                    nextToken();
                    if (token.value == TOK.comma && peekNext() != TOK.rightParentheses)
                        args = parseArguments(); // pragma(identifier, args...)
                    else
                        check(TOK.rightParentheses); // pragma(identifier)

                    AST.Dsymbols* a2 = null;
                    if (token.value == TOK.semicolon)
                    {
                        /* https://issues.dlang.org/show_bug.cgi?id=2354
                         * Accept single semicolon as an empty
                         * DeclarationBlock following attribute.
                         *
                         * Attribute DeclarationBlock
                         * Pragma    DeclDef
                         *           ;
                         */
                        nextToken();
                    }
                    else
                        a2 = parseBlock(pLastDecl);
                    s = new AST.PragmaDeclaration(loc, ident, args, a2);
                    break;
                }
            case TOK.debug_:
                nextToken();
                if (token.value == TOK.assign)
                {
                    nextToken();
                    if (token.value == TOK.identifier)
                        s = new AST.DebugSymbol(token.loc, token.ident);
                    else if (token.value == TOK.int32Literal || token.value == TOK.int64Literal)
                        s = new AST.DebugSymbol(token.loc, cast(uint)token.unsvalue);
                    else
                    {
                        error("identifier or integer expected, not `%s`", token.toChars());
                        s = null;
                    }
                    nextToken();
                    if (token.value != TOK.semicolon)
                        error("semicolon expected");
                    nextToken();
                    break;
                }

                condition = parseDebugCondition();
                goto Lcondition;

            case TOK.version_:
                nextToken();
                if (token.value == TOK.assign)
                {
                    nextToken();
                    if (token.value == TOK.identifier)
                        s = new AST.VersionSymbol(token.loc, token.ident);
                    else if (token.value == TOK.int32Literal || token.value == TOK.int64Literal)
                        s = new AST.VersionSymbol(token.loc, cast(uint)token.unsvalue);
                    else
                    {
                        error("identifier or integer expected, not `%s`", token.toChars());
                        s = null;
                    }
                    nextToken();
                    if (token.value != TOK.semicolon)
                        error("semicolon expected");
                    nextToken();
                    break;
                }
                condition = parseVersionCondition();
                goto Lcondition;

            Lcondition:
                {
                    AST.Dsymbols* athen;
                    if (token.value == TOK.colon)
                        athen = parseBlock(pLastDecl);
                    else
                    {
                        const lookingForElseSave = lookingForElse;
                        lookingForElse = token.loc;
                        athen = parseBlock(pLastDecl);
                        lookingForElse = lookingForElseSave;
                    }
                    AST.Dsymbols* aelse = null;
                    if (token.value == TOK.else_)
                    {
                        const elseloc = token.loc;
                        nextToken();
                        aelse = parseBlock(pLastDecl);
                        checkDanglingElse(elseloc);
                    }
                    s = new AST.ConditionalDeclaration(condition, athen, aelse);
                    break;
                }
            case TOK.semicolon:
                // empty declaration
                //error("empty declaration");
                nextToken();
                continue;

            default:
                error("declaration expected, not `%s`", token.toChars());
            Lerror:
                while (token.value != TOK.semicolon && token.value != TOK.endOfFile)
                    nextToken();
                nextToken();
                s = null;
                continue;
            }

            if (s)
            {
                if (!s.isAttribDeclaration())
                    *pLastDecl = s;
                decldefs.push(s);
                addComment(s, pAttrs.comment);
            }
            else if (a && a.dim)
            {
                decldefs.append(a);
            }
        }
        while (!once);

        linkage = linksave;

        return decldefs;
    }

    /*****************************************
     * Parse auto declarations of the form:
     *   storageClass ident = init, ident = init, ... ;
     * and return the array of them.
     * Starts with token on the first ident.
     * Ends with scanner past closing ';'
     */
    private AST.Dsymbols* parseAutoDeclarations(StorageClass storageClass, const(char)* comment)
    {
        //printf("parseAutoDeclarations\n");
        auto a = new AST.Dsymbols();

        while (1)
        {
            const loc = token.loc;
            Identifier ident = token.ident;
            nextToken(); // skip over ident

            AST.TemplateParameters* tpl = null;
            if (token.value == TOK.leftParentheses)
                tpl = parseTemplateParameterList();

            check(TOK.assign);   // skip over '='
            AST.Initializer _init = parseInitializer();
            auto v = new AST.VarDeclaration(loc, null, ident, _init, storageClass);

            AST.Dsymbol s = v;
            if (tpl)
            {
                auto a2 = new AST.Dsymbols();
                a2.push(v);
                auto tempdecl = new AST.TemplateDeclaration(loc, ident, tpl, null, a2, 0);
                s = tempdecl;
            }
            a.push(s);
            switch (token.value)
            {
            case TOK.semicolon:
                nextToken();
                addComment(s, comment);
                break;

            case TOK.comma:
                nextToken();
                if (!(token.value == TOK.identifier && hasOptionalParensThen(peek(&token), TOK.assign)))
                {
                    error("identifier expected following comma");
                    break;
                }
                addComment(s, comment);
                continue;

            default:
                error("semicolon expected following auto declaration, not `%s`", token.toChars());
                break;
            }
            break;
        }
        return a;
    }

    /********************************************
     * Parse declarations after an align, protection, or extern decl.
     */
    private AST.Dsymbols* parseBlock(AST.Dsymbol* pLastDecl, PrefixAttributes!AST* pAttrs = null)
    {
        AST.Dsymbols* a = null;

        //printf("parseBlock()\n");
        switch (token.value)
        {
        case TOK.semicolon:
            error("declaration expected following attribute, not `;`");
            nextToken();
            break;

        case TOK.endOfFile:
            error("declaration expected following attribute, not end of file");
            break;

        case TOK.leftCurly:
            {
                const lookingForElseSave = lookingForElse;
                lookingForElse = Loc();

                nextToken();
                a = parseDeclDefs(0, pLastDecl);
                if (token.value != TOK.rightCurly)
                {
                    /* { */
                    error("matching `}` expected, not `%s`", token.toChars());
                }
                else
                    nextToken();
                lookingForElse = lookingForElseSave;
                break;
            }
        case TOK.colon:
            nextToken();
            a = parseDeclDefs(0, pLastDecl); // grab declarations up to closing curly bracket
            break;

        default:
            a = parseDeclDefs(1, pLastDecl, pAttrs);
            break;
        }
        return a;
    }

    /*********************************************
     * Give error on redundant/conflicting storage class.
     */
    private StorageClass appendStorageClass(StorageClass storageClass, StorageClass stc)
    {
        if ((storageClass & stc) || (storageClass & STC.in_ && stc & (STC.const_ | STC.scope_)) || (stc & STC.in_ && storageClass & (STC.const_ | STC.scope_)))
        {
            OutBuffer buf;
            AST.stcToBuffer(&buf, stc);
            error("redundant attribute `%s`", buf.peekChars());
            return storageClass | stc;
        }

        storageClass |= stc;

        if (stc & (STC.const_ | STC.immutable_ | STC.manifest))
        {
            StorageClass u = storageClass & (STC.const_ | STC.immutable_ | STC.manifest);
            if (u & (u - 1))
                error("conflicting attribute `%s`", Token.toChars(token.value));
        }
        if (stc & (STC.gshared | STC.shared_ | STC.tls))
        {
            StorageClass u = storageClass & (STC.gshared | STC.shared_ | STC.tls);
            if (u & (u - 1))
                error("conflicting attribute `%s`", Token.toChars(token.value));
        }
        if (stc & STC.safeGroup)
        {
            StorageClass u = storageClass & STC.safeGroup;
            if (u & (u - 1))
                error("conflicting attribute `@%s`", token.toChars());
        }

        return storageClass;
    }

    /***********************************************
     * Parse attribute, lexer is on '@'.
     * Input:
     *      pudas           array of UDAs to append to
     * Returns:
     *      storage class   if a predefined attribute; also scanner remains on identifier.
     *      0               if not a predefined attribute
     *      *pudas          set if user defined attribute, scanner is past UDA
     *      *pudas          NULL if not a user defined attribute
     */
    private StorageClass parseAttribute(AST.Expressions** pudas)
    {
        nextToken();
        AST.Expressions* udas = null;
        StorageClass stc = 0;
        if (token.value == TOK.identifier)
        {
            stc = isBuiltinAtAttribute(token.ident);
            if (!stc)
            {
                // Allow identifier, template instantiation, or function call
                AST.Expression exp = parsePrimaryExp();
                if (token.value == TOK.leftParentheses)
                {
                    const loc = token.loc;
                    exp = new AST.CallExp(loc, exp, parseArguments());
                }

                udas = new AST.Expressions();
                udas.push(exp);
            }
        }
        else if (token.value == TOK.leftParentheses)
        {
            // @( ArgumentList )
            // Concatenate with existing
            if (peekNext() == TOK.rightParentheses)
                error("empty attribute list is not allowed");
            udas = parseArguments();
        }
        else
        {
            error("@identifier or @(ArgumentList) expected, not `@%s`", token.toChars());
        }

        if (stc)
        {
        }
        else if (udas)
        {
            *pudas = AST.UserAttributeDeclaration.concat(*pudas, udas);
        }
        else
            error("valid attributes are `@property`, `@safe`, `@trusted`, `@system`, `@disable`, `@nogc`");
        return stc;
    }

    /***********************************************
     * Parse const/immutable/shared/inout/nothrow/pure postfix
     */
    private StorageClass parsePostfix(StorageClass storageClass, AST.Expressions** pudas)
    {
        while (1)
        {
            StorageClass stc;
            switch (token.value)
            {
            case TOK.const_:
                stc = STC.const_;
                break;

            case TOK.immutable_:
                stc = STC.immutable_;
                break;

            case TOK.shared_:
                stc = STC.shared_;
                break;

            case TOK.inout_:
                stc = STC.wild;
                break;

            case TOK.nothrow_:
                stc = STC.nothrow_;
                break;

            case TOK.pure_:
                stc = STC.pure_;
                break;

            case TOK.return_:
                stc = STC.return_;
                break;

            case TOK.scope_:
                stc = STC.scope_;
                break;

            case TOK.at:
                {
                    AST.Expressions* udas = null;
                    stc = parseAttribute(&udas);
                    if (udas)
                    {
                        if (pudas)
                            *pudas = AST.UserAttributeDeclaration.concat(*pudas, udas);
                        else
                        {
                            // Disallow:
                            //      void function() @uda fp;
                            //      () @uda { return 1; }
                            error("user-defined attributes cannot appear as postfixes");
                        }
                        continue;
                    }
                    break;
                }
            default:
                return storageClass;
            }
            storageClass = appendStorageClass(storageClass, stc);
            nextToken();
        }
    }

    private StorageClass parseTypeCtor()
    {
        StorageClass storageClass = STC.undefined_;

        while (1)
        {
            if (peekNext() == TOK.leftParentheses)
                return storageClass;

            StorageClass stc;
            switch (token.value)
            {
            case TOK.const_:
                stc = STC.const_;
                break;

            case TOK.immutable_:
                stc = STC.immutable_;
                break;

            case TOK.shared_:
                stc = STC.shared_;
                break;

            case TOK.inout_:
                stc = STC.wild;
                break;

            default:
                return storageClass;
            }
            storageClass = appendStorageClass(storageClass, stc);
            nextToken();
        }
    }

    /**************************************
     * Parse constraint.
     * Constraint is of the form:
     *      if ( ConstraintExpression )
     */
    private AST.Expression parseConstraint()
    {
        AST.Expression e = null;
        if (token.value == TOK.if_)
        {
            nextToken(); // skip over 'if'
            check(TOK.leftParentheses);
            e = parseExpression();
            check(TOK.rightParentheses);
        }
        return e;
    }

    /**************************************
     * Parse a TemplateDeclaration.
     */
    private AST.TemplateDeclaration parseTemplateDeclaration(bool ismixin = false)
    {
        AST.TemplateDeclaration tempdecl;
        Identifier id;
        AST.TemplateParameters* tpl;
        AST.Dsymbols* decldefs;
        AST.Expression constraint = null;
        const loc = token.loc;

        nextToken();
        if (token.value != TOK.identifier)
        {
            error("identifier expected following `template`");
            goto Lerr;
        }
        id = token.ident;
        nextToken();
        tpl = parseTemplateParameterList();
        if (!tpl)
            goto Lerr;

        constraint = parseConstraint();

        if (token.value != TOK.leftCurly)
        {
            error("members of template declaration expected");
            goto Lerr;
        }
        decldefs = parseBlock(null);

        tempdecl = new AST.TemplateDeclaration(loc, id, tpl, constraint, decldefs, ismixin);
        return tempdecl;

    Lerr:
        return null;
    }

    /******************************************
     * Parse template parameter list.
     * Input:
     *      flag    0: parsing "( list )"
     *              1: parsing non-empty "list $(RPAREN)"
     */
    private AST.TemplateParameters* parseTemplateParameterList(int flag = 0)
    {
        auto tpl = new AST.TemplateParameters();

        if (!flag && token.value != TOK.leftParentheses)
        {
            error("parenthesized template parameter list expected following template identifier");
            goto Lerr;
        }
        nextToken();

        // Get array of TemplateParameters
        if (flag || token.value != TOK.rightParentheses)
        {
            int isvariadic = 0;
            while (token.value != TOK.rightParentheses)
            {
                AST.TemplateParameter tp;
                Loc loc;
                Identifier tp_ident = null;
                AST.Type tp_spectype = null;
                AST.Type tp_valtype = null;
                AST.Type tp_defaulttype = null;
                AST.Expression tp_specvalue = null;
                AST.Expression tp_defaultvalue = null;

                // Get TemplateParameter

                // First, look ahead to see if it is a TypeParameter or a ValueParameter
                const tv = peekNext();
                if (token.value == TOK.alias_)
                {
                    // AliasParameter
                    nextToken();
                    loc = token.loc; // todo
                    AST.Type spectype = null;
                    if (isDeclaration(&token, NeedDeclaratorId.must, TOK.reserved, null))
                    {
                        spectype = parseType(&tp_ident);
                    }
                    else
                    {
                        if (token.value != TOK.identifier)
                        {
                            error("identifier expected for template alias parameter");
                            goto Lerr;
                        }
                        tp_ident = token.ident;
                        nextToken();
                    }
                    RootObject spec = null;
                    if (token.value == TOK.colon) // : Type
                    {
                        nextToken();
                        if (isDeclaration(&token, NeedDeclaratorId.no, TOK.reserved, null))
                            spec = parseType();
                        else
                            spec = parseCondExp();
                    }
                    RootObject def = null;
                    if (token.value == TOK.assign) // = Type
                    {
                        nextToken();
                        if (isDeclaration(&token, NeedDeclaratorId.no, TOK.reserved, null))
                            def = parseType();
                        else
                            def = parseCondExp();
                    }
                    tp = new AST.TemplateAliasParameter(loc, tp_ident, spectype, spec, def);
                }
                else if (tv == TOK.colon || tv == TOK.assign || tv == TOK.comma || tv == TOK.rightParentheses)
                {
                    // TypeParameter
                    if (token.value != TOK.identifier)
                    {
                        error("identifier expected for template type parameter");
                        goto Lerr;
                    }
                    loc = token.loc;
                    tp_ident = token.ident;
                    nextToken();
                    if (token.value == TOK.colon) // : Type
                    {
                        nextToken();
                        tp_spectype = parseType();
                    }
                    if (token.value == TOK.assign) // = Type
                    {
                        nextToken();
                        tp_defaulttype = parseType();
                    }
                    tp = new AST.TemplateTypeParameter(loc, tp_ident, tp_spectype, tp_defaulttype);
                }
                else if (token.value == TOK.identifier && tv == TOK.dotDotDot)
                {
                    // ident...
                    if (isvariadic)
                        error("variadic template parameter must be last");
                    isvariadic = 1;
                    loc = token.loc;
                    tp_ident = token.ident;
                    nextToken();
                    nextToken();
                    tp = new AST.TemplateTupleParameter(loc, tp_ident);
                }
                else if (token.value == TOK.this_)
                {
                    // ThisParameter
                    nextToken();
                    if (token.value != TOK.identifier)
                    {
                        error("identifier expected for template this parameter");
                        goto Lerr;
                    }
                    loc = token.loc;
                    tp_ident = token.ident;
                    nextToken();
                    if (token.value == TOK.colon) // : Type
                    {
                        nextToken();
                        tp_spectype = parseType();
                    }
                    if (token.value == TOK.assign) // = Type
                    {
                        nextToken();
                        tp_defaulttype = parseType();
                    }
                    tp = new AST.TemplateThisParameter(loc, tp_ident, tp_spectype, tp_defaulttype);
                }
                else
                {
                    // ValueParameter
                    loc = token.loc; // todo
                    tp_valtype = parseType(&tp_ident);
                    if (!tp_ident)
                    {
                        error("identifier expected for template value parameter");
                        tp_ident = Identifier.idPool("error");
                    }
                    if (token.value == TOK.colon) // : CondExpression
                    {
                        nextToken();
                        tp_specvalue = parseCondExp();
                    }
                    if (token.value == TOK.assign) // = CondExpression
                    {
                        nextToken();
                        tp_defaultvalue = parseDefaultInitExp();
                    }
                    tp = new AST.TemplateValueParameter(loc, tp_ident, tp_valtype, tp_specvalue, tp_defaultvalue);
                }
                tpl.push(tp);
                if (token.value != TOK.comma)
                    break;
                nextToken();
            }
        }
        check(TOK.rightParentheses);

    Lerr:
        return tpl;
    }

    /******************************************
     * Parse template mixin.
     *      mixin Foo;
     *      mixin Foo!(args);
     *      mixin a.b.c!(args).Foo!(args);
     *      mixin Foo!(args) identifier;
     *      mixin typeof(expr).identifier!(args);
     */
    private AST.Dsymbol parseMixin()
    {
        AST.TemplateMixin tm;
        Identifier id;
        AST.Objects* tiargs;

        //printf("parseMixin()\n");
        const locMixin = token.loc;
        nextToken(); // skip 'mixin'

        auto loc = token.loc;
        AST.TypeQualified tqual = null;
        if (token.value == TOK.dot)
        {
            id = Id.empty;
        }
        else
        {
            if (token.value == TOK.typeof_)
            {
                tqual = parseTypeof();
                check(TOK.dot);
            }
            if (token.value != TOK.identifier)
            {
                error("identifier expected, not `%s`", token.toChars());
                id = Id.empty;
            }
            else
                id = token.ident;
            nextToken();
        }

        while (1)
        {
            tiargs = null;
            if (token.value == TOK.not)
            {
                tiargs = parseTemplateArguments();
            }

            if (tiargs && token.value == TOK.dot)
            {
                auto tempinst = new AST.TemplateInstance(loc, id, tiargs);
                if (!tqual)
                    tqual = new AST.TypeInstance(loc, tempinst);
                else
                    tqual.addInst(tempinst);
                tiargs = null;
            }
            else
            {
                if (!tqual)
                    tqual = new AST.TypeIdentifier(loc, id);
                else
                    tqual.addIdent(id);
            }

            if (token.value != TOK.dot)
                break;

            nextToken();
            if (token.value != TOK.identifier)
            {
                error("identifier expected following `.` instead of `%s`", token.toChars());
                break;
            }
            loc = token.loc;
            id = token.ident;
            nextToken();
        }

        id = null;
        if (token.value == TOK.identifier)
        {
            id = token.ident;
            nextToken();
        }

        tm = new AST.TemplateMixin(locMixin, id, tqual, tiargs);
        if (token.value != TOK.semicolon)
            error("`;` expected after mixin");
        nextToken();

        return tm;
    }

    /******************************************
     * Parse template arguments.
     * Input:
     *      current token is opening '!'
     * Output:
     *      current token is one after closing '$(RPAREN)'
     */
    private AST.Objects* parseTemplateArguments()
    {
        AST.Objects* tiargs;

        nextToken();
        if (token.value == TOK.leftParentheses)
        {
            // ident!(template_arguments)
            tiargs = parseTemplateArgumentList();
        }
        else
        {
            // ident!template_argument
            tiargs = parseTemplateSingleArgument();
        }
        if (token.value == TOK.not)
        {
            TOK tok = peekNext();
            if (tok != TOK.is_ && tok != TOK.in_)
            {
                error("multiple ! arguments are not allowed");
            Lagain:
                nextToken();
                if (token.value == TOK.leftParentheses)
                    parseTemplateArgumentList();
                else
                    parseTemplateSingleArgument();
                if (token.value == TOK.not && (tok = peekNext()) != TOK.is_ && tok != TOK.in_)
                    goto Lagain;
            }
        }
        return tiargs;
    }

    /******************************************
     * Parse template argument list.
     * Input:
     *      current token is opening '$(LPAREN)',
     *          or ',' for __traits
     * Output:
     *      current token is one after closing '$(RPAREN)'
     */
    private AST.Objects* parseTemplateArgumentList()
    {
        //printf("Parser::parseTemplateArgumentList()\n");
        auto tiargs = new AST.Objects();
        TOK endtok = TOK.rightParentheses;
        assert(token.value == TOK.leftParentheses || token.value == TOK.comma);
        nextToken();

        // Get TemplateArgumentList
        while (token.value != endtok)
        {
            tiargs.push(parseTypeOrAssignExp());
            if (token.value != TOK.comma)
                break;
            nextToken();
        }
        check(endtok, "template argument list");
        return tiargs;
    }

    /***************************************
     * Parse a Type or an Expression
     * Returns:
     *  RootObject representing the AST
     */
    RootObject parseTypeOrAssignExp(TOK endtoken = TOK.reserved)
    {
        return isDeclaration(&token, NeedDeclaratorId.no, endtoken, null)
            ? parseType()           // argument is a type
            : parseAssignExp();     // argument is an expression
    }

    /*****************************
     * Parse single template argument, to support the syntax:
     *      foo!arg
     * Input:
     *      current token is the arg
     */
    private AST.Objects* parseTemplateSingleArgument()
    {
        //printf("parseTemplateSingleArgument()\n");
        auto tiargs = new AST.Objects();
        AST.Type ta;
        switch (token.value)
        {
        case TOK.identifier:
            ta = new AST.TypeIdentifier(token.loc, token.ident);
            goto LabelX;

        case TOK.vector:
            ta = parseVector();
            goto LabelX;

        case TOK.void_:
            ta = AST.Type.tvoid;
            goto LabelX;

        case TOK.int8:
            ta = AST.Type.tint8;
            goto LabelX;

        case TOK.uns8:
            ta = AST.Type.tuns8;
            goto LabelX;

        case TOK.int16:
            ta = AST.Type.tint16;
            goto LabelX;

        case TOK.uns16:
            ta = AST.Type.tuns16;
            goto LabelX;

        case TOK.int32:
            ta = AST.Type.tint32;
            goto LabelX;

        case TOK.uns32:
            ta = AST.Type.tuns32;
            goto LabelX;

        case TOK.int64:
            ta = AST.Type.tint64;
            goto LabelX;

        case TOK.uns64:
            ta = AST.Type.tuns64;
            goto LabelX;

        case TOK.int128:
            ta = AST.Type.tint128;
            goto LabelX;

        case TOK.uns128:
            ta = AST.Type.tuns128;
            goto LabelX;

        case TOK.float32:
            ta = AST.Type.tfloat32;
            goto LabelX;

        case TOK.float64:
            ta = AST.Type.tfloat64;
            goto LabelX;

        case TOK.float80:
            ta = AST.Type.tfloat80;
            goto LabelX;

        case TOK.imaginary32:
            ta = AST.Type.timaginary32;
            goto LabelX;

        case TOK.imaginary64:
            ta = AST.Type.timaginary64;
            goto LabelX;

        case TOK.imaginary80:
            ta = AST.Type.timaginary80;
            goto LabelX;

        case TOK.complex32:
            ta = AST.Type.tcomplex32;
            goto LabelX;

        case TOK.complex64:
            ta = AST.Type.tcomplex64;
            goto LabelX;

        case TOK.complex80:
            ta = AST.Type.tcomplex80;
            goto LabelX;

        case TOK.bool_:
            ta = AST.Type.tbool;
            goto LabelX;

        case TOK.char_:
            ta = AST.Type.tchar;
            goto LabelX;

        case TOK.wchar_:
            ta = AST.Type.twchar;
            goto LabelX;

        case TOK.dchar_:
            ta = AST.Type.tdchar;
            goto LabelX;
        LabelX:
            tiargs.push(ta);
            nextToken();
            break;

        case TOK.int32Literal:
        case TOK.uns32Literal:
        case TOK.int64Literal:
        case TOK.uns64Literal:
        case TOK.int128Literal:
        case TOK.uns128Literal:
        case TOK.float32Literal:
        case TOK.float64Literal:
        case TOK.float80Literal:
        case TOK.imaginary32Literal:
        case TOK.imaginary64Literal:
        case TOK.imaginary80Literal:
        case TOK.null_:
        case TOK.true_:
        case TOK.false_:
        case TOK.charLiteral:
        case TOK.wcharLiteral:
        case TOK.dcharLiteral:
        case TOK.string_:
        case TOK.hexadecimalString:
        case TOK.file:
        case TOK.fileFullPath:
        case TOK.line:
        case TOK.moduleString:
        case TOK.functionString:
        case TOK.prettyFunction:
        case TOK.this_:
            {
                // Template argument is an expression
                AST.Expression ea = parsePrimaryExp();
                tiargs.push(ea);
                break;
            }
        default:
            error("template argument expected following `!`");
            break;
        }
        return tiargs;
    }

    /**********************************
     * Parse a static assertion.
     * Current token is 'static'.
     */
    private AST.StaticAssert parseStaticAssert()
    {
        const loc = token.loc;
        AST.Expression exp;
        AST.Expression msg = null;

        //printf("parseStaticAssert()\n");
        nextToken();
        nextToken();
        check(TOK.leftParentheses);
        exp = parseAssignExp();
        if (token.value == TOK.comma)
        {
            nextToken();
            if (token.value != TOK.rightParentheses)
            {
                msg = parseAssignExp();
                if (token.value == TOK.comma)
                    nextToken();
            }
        }
        check(TOK.rightParentheses);
        check(TOK.semicolon);
        return new AST.StaticAssert(loc, exp, msg);
    }

    /***********************************
     * Parse typeof(expression).
     * Current token is on the 'typeof'.
     */
    private AST.TypeQualified parseTypeof()
    {
        AST.TypeQualified t;
        const loc = token.loc;

        nextToken();
        check(TOK.leftParentheses);
        if (token.value == TOK.return_) // typeof(return)
        {
            nextToken();
            t = new AST.TypeReturn(loc);
        }
        else
        {
            AST.Expression exp = parseExpression(); // typeof(expression)
            t = new AST.TypeTypeof(loc, exp);
        }
        check(TOK.rightParentheses);
        return t;
    }

    /***********************************
     * Parse __vector(type).
     * Current token is on the '__vector'.
     */
    private AST.Type parseVector()
    {
        nextToken();
        check(TOK.leftParentheses);
        AST.Type tb = parseType();
        check(TOK.rightParentheses);
        return new AST.TypeVector(tb);
    }

    /***********************************
     * Parse:
     *      extern (linkage)
     *      extern (C++, namespaces)
     *      extern (C++, "namespace", "namespaces", ...)
     *      extern (C++, (StringExp))
     * The parser is on the 'extern' token.
     */
    private LINK parseLinkage(AST.Identifiers** pidents, AST.Expressions** pIdentExps, out CPPMANGLE cppmangle, out bool cppMangleOnly)
    {
        AST.Identifiers* idents = null;
        AST.Expressions* identExps = null;
        cppmangle = CPPMANGLE.def;
        LINK link = LINK.d; // default
        nextToken();
        assert(token.value == TOK.leftParentheses);
        nextToken();
        if (token.value == TOK.identifier)
        {
            Identifier id = token.ident;
            nextToken();
            if (id == Id.Windows)
                link = LINK.windows;
            else if (id == Id.Pascal)
            {
                deprecation("`extern(Pascal)` is deprecated. You might want to use `extern(Windows)` instead.");
                link = LINK.pascal;
            }
            else if (id == Id.D)
            { /* already set */}
            else if (id == Id.C)
            {
                link = LINK.c;
                if (token.value == TOK.plusPlus)
                {
                    link = LINK.cpp;
                    nextToken();
                    if (token.value == TOK.comma) // , namespaces or class or struct
                    {
                        nextToken();
                        if (token.value == TOK.class_ || token.value == TOK.struct_)
                        {
                            cppmangle = token.value == TOK.class_ ? CPPMANGLE.asClass : CPPMANGLE.asStruct;
                            nextToken();
                        }
                        else if (token.value == TOK.identifier) // named scope namespace
                        {
                            idents = new AST.Identifiers();
                            while (1)
                            {
                                Identifier idn = token.ident;
                                idents.push(idn);
                                nextToken();
                                if (token.value == TOK.dot)
                                {
                                    nextToken();
                                    if (token.value == TOK.identifier)
                                        continue;
                                    error("identifier expected for C++ namespace");
                                    idents = null;  // error occurred, invalidate list of elements.
                                }
                                break;
                            }
                        }
                        else // non-scoped StringExp namespace
                        {
                            cppMangleOnly = true;
                            identExps = new AST.Expressions();
                            while (1)
                            {
                                identExps.push(parseCondExp());
                                if (token.value != TOK.comma)
                                    break;
                                nextToken();
                            }
                        }
                    }
                }
            }
            else if (id == Id.Objective) // Looking for tokens "Objective-C"
            {
                if (token.value == TOK.min)
                {
                    nextToken();
                    if (token.ident == Id.C)
                    {
                        link = LINK.objc;
                        nextToken();
                    }
                    else
                        goto LinvalidLinkage;
                }
                else
                    goto LinvalidLinkage;
            }
            else if (id == Id.System)
            {
                link = LINK.system;
            }
            else
            {
            LinvalidLinkage:
                error("valid linkage identifiers are `D`, `C`, `C++`, `Objective-C`, `Pascal`, `Windows`, `System`");
                link = LINK.d;
            }
        }
        check(TOK.rightParentheses);
        *pidents = idents;
        *pIdentExps = identExps;
        return link;
    }

    /***********************************
     * Parse ident1.ident2.ident3
     *
     * Params:
     *  entity = what qualified identifier is expected to resolve into.
     *     Used only for better error message
     *
     * Returns:
     *     array of identifiers with actual qualified one stored last
     */
    private AST.Identifiers* parseQualifiedIdentifier(const(char)* entity)
    {
        AST.Identifiers* qualified = null;

        do
        {
            nextToken();
            if (token.value != TOK.identifier)
            {
                error("`%s` expected as dot-separated identifiers, got `%s`", entity, token.toChars());
                return null;
            }

            Identifier id = token.ident;
            if (!qualified)
                qualified = new AST.Identifiers();
            qualified.push(id);

            nextToken();
        }
        while (token.value == TOK.dot);

        return qualified;
    }

    /**************************************
     * Parse a debug conditional
     */
    private AST.Condition parseDebugCondition()
    {
        uint level = 1;
        Identifier id = null;

        if (token.value == TOK.leftParentheses)
        {
            nextToken();

            if (token.value == TOK.identifier)
                id = token.ident;
            else if (token.value == TOK.int32Literal || token.value == TOK.int64Literal)
                level = cast(uint)token.unsvalue;
            else
                error("identifier or integer expected inside debug(...), not `%s`", token.toChars());
            nextToken();
            check(TOK.rightParentheses);
        }
        return new AST.DebugCondition(mod, level, id);
    }

    /**************************************
     * Parse a version conditional
     */
    private AST.Condition parseVersionCondition()
    {
        uint level = 1;
        Identifier id = null;

        if (token.value == TOK.leftParentheses)
        {
            nextToken();
            /* Allow:
             *    version (unittest)
             *    version (assert)
             * even though they are keywords
             */
            if (token.value == TOK.identifier)
                id = token.ident;
            else if (token.value == TOK.int32Literal || token.value == TOK.int64Literal)
                level = cast(uint)token.unsvalue;
            else if (token.value == TOK.unittest_)
                id = Identifier.idPool(Token.toString(TOK.unittest_));
            else if (token.value == TOK.assert_)
                id = Identifier.idPool(Token.toString(TOK.assert_));
            else
                error("identifier or integer expected inside version(...), not `%s`", token.toChars());
            nextToken();
            check(TOK.rightParentheses);
        }
        else
            error("(condition) expected following `version`");
        return new AST.VersionCondition(mod, level, id);
    }

    /***********************************************
     *      static if (expression)
     *          body
     *      else
     *          body
     * Current token is 'static'.
     */
    private AST.Condition parseStaticIfCondition()
    {
        AST.Expression exp;
        AST.Condition condition;
        const loc = token.loc;

        nextToken();
        nextToken();
        if (token.value == TOK.leftParentheses)
        {
            nextToken();
            exp = parseAssignExp();
            check(TOK.rightParentheses);
        }
        else
        {
            error("(expression) expected following `static if`");
            exp = null;
        }
        condition = new AST.StaticIfCondition(loc, exp);
        return condition;
    }

    /*****************************************
     * Parse a constructor definition:
     *      this(parameters) { body }
     * or postblit:
     *      this(this) { body }
     * or constructor template:
     *      this(templateparameters)(parameters) { body }
     * Current token is 'this'.
     */
    private AST.Dsymbol parseCtor(PrefixAttributes!AST* pAttrs)
    {
        AST.Expressions* udas = null;
        const loc = token.loc;
        StorageClass stc = getStorageClass!AST(pAttrs);

        nextToken();
        if (token.value == TOK.leftParentheses && peekNext() == TOK.this_ && peekNext2() == TOK.rightParentheses)
        {
            // this(this) { ... }
            nextToken();
            nextToken();
            check(TOK.rightParentheses);

            stc = parsePostfix(stc, &udas);
            if (stc & STC.immutable_)
                deprecation("`immutable` postblit is deprecated. Please use an unqualified postblit.");
            if (stc & STC.shared_)
                deprecation("`shared` postblit is deprecated. Please use an unqualified postblit.");
            if (stc & STC.const_)
                deprecation("`const` postblit is deprecated. Please use an unqualified postblit.");
            if (stc & STC.static_)
                error(loc, "postblit cannot be `static`");

            auto f = new AST.PostBlitDeclaration(loc, Loc.initial, stc, Id.postblit);
            AST.Dsymbol s = parseContracts(f);
            if (udas)
            {
                auto a = new AST.Dsymbols();
                a.push(f);
                s = new AST.UserAttributeDeclaration(udas, a);
            }
            return s;
        }

        /* Look ahead to see if:
         *   this(...)(...)
         * which is a constructor template
         */
        AST.TemplateParameters* tpl = null;
        if (token.value == TOK.leftParentheses && peekPastParen(&token).value == TOK.leftParentheses)
        {
            tpl = parseTemplateParameterList();
        }

        /* Just a regular constructor
         */
        AST.VarArg varargs;
        AST.Parameters* parameters = parseParameters(&varargs);
        stc = parsePostfix(stc, &udas);

        if (varargs != AST.VarArg.none || AST.Parameter.dim(parameters) != 0)
        {
            if (stc & STC.static_)
                error(loc, "constructor cannot be static");
        }
        else if (StorageClass ss = stc & (STC.shared_ | STC.static_)) // this()
        {
            if (ss == STC.static_)
                error(loc, "use `static this()` to declare a static constructor");
            else if (ss == (STC.shared_ | STC.static_))
                error(loc, "use `shared static this()` to declare a shared static constructor");
        }

        AST.Expression constraint = tpl ? parseConstraint() : null;

        AST.Type tf = new AST.TypeFunction(AST.ParameterList(parameters, varargs), null, linkage, stc); // RetrunType -> auto
        tf = tf.addSTC(stc);

        auto f = new AST.CtorDeclaration(loc, Loc.initial, stc, tf);
        AST.Dsymbol s = parseContracts(f);
        if (udas)
        {
            auto a = new AST.Dsymbols();
            a.push(f);
            s = new AST.UserAttributeDeclaration(udas, a);
        }

        if (tpl)
        {
            // Wrap a template around it
            auto decldefs = new AST.Dsymbols();
            decldefs.push(s);
            s = new AST.TemplateDeclaration(loc, f.ident, tpl, constraint, decldefs);
        }

        return s;
    }

    /*****************************************
     * Parse a destructor definition:
     *      ~this() { body }
     * Current token is '~'.
     */
    private AST.Dsymbol parseDtor(PrefixAttributes!AST* pAttrs)
    {
        AST.Expressions* udas = null;
        const loc = token.loc;
        StorageClass stc = getStorageClass!AST(pAttrs);

        nextToken();
        check(TOK.this_);
        check(TOK.leftParentheses);
        check(TOK.rightParentheses);

        stc = parsePostfix(stc, &udas);
        if (StorageClass ss = stc & (STC.shared_ | STC.static_))
        {
            if (ss == STC.static_)
                error(loc, "use `static ~this()` to declare a static destructor");
            else if (ss == (STC.shared_ | STC.static_))
                error(loc, "use `shared static ~this()` to declare a shared static destructor");
        }

        auto f = new AST.DtorDeclaration(loc, Loc.initial, stc, Id.dtor);
        AST.Dsymbol s = parseContracts(f);
        if (udas)
        {
            auto a = new AST.Dsymbols();
            a.push(f);
            s = new AST.UserAttributeDeclaration(udas, a);
        }
        return s;
    }

    /*****************************************
     * Parse a static constructor definition:
     *      static this() { body }
     * Current token is 'static'.
     */
    private AST.Dsymbol parseStaticCtor(PrefixAttributes!AST* pAttrs)
    {
        //Expressions *udas = NULL;
        const loc = token.loc;
        StorageClass stc = getStorageClass!AST(pAttrs);

        nextToken();
        nextToken();
        check(TOK.leftParentheses);
        check(TOK.rightParentheses);

        stc = parsePostfix(stc & ~STC.TYPECTOR, null) | stc;
        if (stc & STC.shared_)
            error(loc, "use `shared static this()` to declare a shared static constructor");
        else if (stc & STC.static_)
            appendStorageClass(stc, STC.static_); // complaint for the redundancy
        else if (StorageClass modStc = stc & STC.TYPECTOR)
        {
            OutBuffer buf;
            AST.stcToBuffer(&buf, modStc);
            error(loc, "static constructor cannot be `%s`", buf.peekChars());
        }
        stc &= ~(STC.static_ | STC.TYPECTOR);

        auto f = new AST.StaticCtorDeclaration(loc, Loc.initial, stc);
        AST.Dsymbol s = parseContracts(f);
        return s;
    }

    /*****************************************
     * Parse a static destructor definition:
     *      static ~this() { body }
     * Current token is 'static'.
     */
    private AST.Dsymbol parseStaticDtor(PrefixAttributes!AST* pAttrs)
    {
        AST.Expressions* udas = null;
        const loc = token.loc;
        StorageClass stc = getStorageClass!AST(pAttrs);

        nextToken();
        nextToken();
        check(TOK.this_);
        check(TOK.leftParentheses);
        check(TOK.rightParentheses);

        stc = parsePostfix(stc & ~STC.TYPECTOR, &udas) | stc;
        if (stc & STC.shared_)
            error(loc, "use `shared static ~this()` to declare a shared static destructor");
        else if (stc & STC.static_)
            appendStorageClass(stc, STC.static_); // complaint for the redundancy
        else if (StorageClass modStc = stc & STC.TYPECTOR)
        {
            OutBuffer buf;
            AST.stcToBuffer(&buf, modStc);
            error(loc, "static destructor cannot be `%s`", buf.peekChars());
        }
        stc &= ~(STC.static_ | STC.TYPECTOR);

        auto f = new AST.StaticDtorDeclaration(loc, Loc.initial, stc);
        AST.Dsymbol s = parseContracts(f);
        if (udas)
        {
            auto a = new AST.Dsymbols();
            a.push(f);
            s = new AST.UserAttributeDeclaration(udas, a);
        }
        return s;
    }

    /*****************************************
     * Parse a shared static constructor definition:
     *      shared static this() { body }
     * Current token is 'shared'.
     */
    private AST.Dsymbol parseSharedStaticCtor(PrefixAttributes!AST* pAttrs)
    {
        //Expressions *udas = NULL;
        const loc = token.loc;
        StorageClass stc = getStorageClass!AST(pAttrs);

        nextToken();
        nextToken();
        nextToken();
        check(TOK.leftParentheses);
        check(TOK.rightParentheses);

        stc = parsePostfix(stc & ~STC.TYPECTOR, null) | stc;
        if (StorageClass ss = stc & (STC.shared_ | STC.static_))
            appendStorageClass(stc, ss); // complaint for the redundancy
        else if (StorageClass modStc = stc & STC.TYPECTOR)
        {
            OutBuffer buf;
            AST.stcToBuffer(&buf, modStc);
            error(loc, "shared static constructor cannot be `%s`", buf.peekChars());
        }
        stc &= ~(STC.static_ | STC.TYPECTOR);

        auto f = new AST.SharedStaticCtorDeclaration(loc, Loc.initial, stc);
        AST.Dsymbol s = parseContracts(f);
        return s;
    }

    /*****************************************
     * Parse a shared static destructor definition:
     *      shared static ~this() { body }
     * Current token is 'shared'.
     */
    private AST.Dsymbol parseSharedStaticDtor(PrefixAttributes!AST* pAttrs)
    {
        AST.Expressions* udas = null;
        const loc = token.loc;
        StorageClass stc = getStorageClass!AST(pAttrs);

        nextToken();
        nextToken();
        nextToken();
        check(TOK.this_);
        check(TOK.leftParentheses);
        check(TOK.rightParentheses);

        stc = parsePostfix(stc & ~STC.TYPECTOR, &udas) | stc;
        if (StorageClass ss = stc & (STC.shared_ | STC.static_))
            appendStorageClass(stc, ss); // complaint for the redundancy
        else if (StorageClass modStc = stc & STC.TYPECTOR)
        {
            OutBuffer buf;
            AST.stcToBuffer(&buf, modStc);
            error(loc, "shared static destructor cannot be `%s`", buf.peekChars());
        }
        stc &= ~(STC.static_ | STC.TYPECTOR);

        auto f = new AST.SharedStaticDtorDeclaration(loc, Loc.initial, stc);
        AST.Dsymbol s = parseContracts(f);
        if (udas)
        {
            auto a = new AST.Dsymbols();
            a.push(f);
            s = new AST.UserAttributeDeclaration(udas, a);
        }
        return s;
    }

    /*****************************************
     * Parse an invariant definition:
     *      invariant { statements... }
     *      invariant() { statements... }
     *      invariant (expression);
     * Current token is 'invariant'.
     */
    private AST.Dsymbol parseInvariant(PrefixAttributes!AST* pAttrs)
    {
        const loc = token.loc;
        StorageClass stc = getStorageClass!AST(pAttrs);

        nextToken();
        if (token.value == TOK.leftParentheses) // optional () or invariant (expression);
        {
            nextToken();
            if (token.value != TOK.rightParentheses) // invariant (expression);
            {
                AST.Expression e = parseAssignExp(), msg = null;
                if (token.value == TOK.comma)
                {
                    nextToken();
                    if (token.value != TOK.rightParentheses)
                    {
                        msg = parseAssignExp();
                        if (token.value == TOK.comma)
                            nextToken();
                    }
                }
                check(TOK.rightParentheses);
                check(TOK.semicolon);
                e = new AST.AssertExp(loc, e, msg);
                auto fbody = new AST.ExpStatement(loc, e);
                auto f = new AST.InvariantDeclaration(loc, token.loc, stc, null, fbody);
                return f;
            }
            nextToken();
        }

        auto fbody = parseStatement(ParseStatementFlags.curly);
        auto f = new AST.InvariantDeclaration(loc, token.loc, stc, null, fbody);
        return f;
    }

    /*****************************************
     * Parse a unittest definition:
     *      unittest { body }
     * Current token is 'unittest'.
     */
    private AST.Dsymbol parseUnitTest(PrefixAttributes!AST* pAttrs)
    {
        const loc = token.loc;
        StorageClass stc = getStorageClass!AST(pAttrs);

        nextToken();

        const(char)* begPtr = token.ptr + 1; // skip '{'
        const(char)* endPtr = null;
        AST.Statement sbody = parseStatement(ParseStatementFlags.curly, &endPtr);

        /** Extract unittest body as a string. Must be done eagerly since memory
         will be released by the lexer before doc gen. */
        char* docline = null;
        if (global.params.doDocComments && endPtr > begPtr)
        {
            /* Remove trailing whitespaces */
            for (const(char)* p = endPtr - 1; begPtr <= p && (*p == ' ' || *p == '\r' || *p == '\n' || *p == '\t'); --p)
            {
                endPtr = p;
            }

            size_t len = endPtr - begPtr;
            if (len > 0)
            {
                docline = cast(char*)mem.xmalloc_noscan(len + 2);
                memcpy(docline, begPtr, len);
                docline[len] = '\n'; // Terminate all lines by LF
                docline[len + 1] = '\0';
            }
        }

        auto f = new AST.UnitTestDeclaration(loc, token.loc, stc, docline);
        f.fbody = sbody;
        return f;
    }

    /*****************************************
     * Parse a new definition:
     *      new(parameters) { body }
     * Current token is 'new'.
     */
    private AST.Dsymbol parseNew(PrefixAttributes!AST* pAttrs)
    {
        const loc = token.loc;
        StorageClass stc = getStorageClass!AST(pAttrs);

        nextToken();

        AST.VarArg varargs;
        AST.Parameters* parameters = parseParameters(&varargs);
        auto f = new AST.NewDeclaration(loc, Loc.initial, stc, parameters, varargs);
        AST.Dsymbol s = parseContracts(f);
        return s;
    }

    /**********************************************
     * Parse parameter list.
     */
    private AST.Parameters* parseParameters(AST.VarArg* pvarargs, AST.TemplateParameters** tpl = null)
    {
        auto parameters = new AST.Parameters();
        AST.VarArg varargs = AST.VarArg.none;
        int hasdefault = 0;

        check(TOK.leftParentheses);
        while (1)
        {
            Identifier ai = null;
            AST.Type at;
            StorageClass storageClass = 0;
            StorageClass stc;
            AST.Expression ae;
            AST.Expressions* udas = null;
            for (; 1; nextToken())
            {
            L3:
                switch (token.value)
                {
                case TOK.rightParentheses:
                    if (storageClass != 0 || udas !is null)
                        error("basic type expected, not `)`");
                    break;

                case TOK.dotDotDot:
                    varargs = AST.VarArg.variadic;
                    nextToken();
                    break;

                case TOK.const_:
                    if (peekNext() == TOK.leftParentheses)
                        goto default;
                    stc = STC.const_;
                    goto L2;

                case TOK.immutable_:
                    if (peekNext() == TOK.leftParentheses)
                        goto default;
                    stc = STC.immutable_;
                    goto L2;

                case TOK.shared_:
                    if (peekNext() == TOK.leftParentheses)
                        goto default;
                    stc = STC.shared_;
                    goto L2;

                case TOK.inout_:
                    if (peekNext() == TOK.leftParentheses)
                        goto default;
                    stc = STC.wild;
                    goto L2;
                case TOK.at:
                    {
                        AST.Expressions* exps = null;
                        StorageClass stc2 = parseAttribute(&exps);
                        if (stc2 & atAttrGroup)
                        {
                            error("`@%s` attribute for function parameter is not supported", token.toChars());
                        }
                        else
                        {
                            udas = AST.UserAttributeDeclaration.concat(udas, exps);
                        }
                        if (token.value == TOK.dotDotDot)
                            error("variadic parameter cannot have user-defined attributes");
                        if (stc2)
                            nextToken();
                        goto L3;
                        // Don't call nextToken again.
                    }
                case TOK.in_:
                    if (global.params.inMeansScopeConst)
                    {
                        // `in` now means `const scope` as originally intented
                        stc = STC.const_ | STC.scope_;
                    }
                    else
                        stc = STC.in_;

                    goto L2;

                case TOK.out_:
                    stc = STC.out_;
                    goto L2;

                case TOK.ref_:
                    stc = STC.ref_;
                    goto L2;

                case TOK.lazy_:
                    stc = STC.lazy_;
                    goto L2;

                case TOK.scope_:
                    stc = STC.scope_;
                    goto L2;

                case TOK.final_:
                    stc = STC.final_;
                    goto L2;

                case TOK.auto_:
                    stc = STC.auto_;
                    goto L2;

                case TOK.return_:
                    stc = STC.return_;
                    goto L2;
                L2:
                    storageClass = appendStorageClass(storageClass, stc);
                    continue;

                    version (none)
                    {
                    case TOK.static_:
                        stc = STC.static_;
                        goto L2;

                    case TOK.auto_:
                        storageClass = STC.auto_;
                        goto L4;

                    case TOK.alias_:
                        storageClass = STC.alias_;
                        goto L4;
                    L4:
                        nextToken();
                        ai = null;
                        if (token.value == TOK.identifier)
                        {
                            ai = token.ident;
                            nextToken();
                        }

                        at = null; // no type
                        ae = null; // no default argument
                        if (token.value == TOK.assign) // = defaultArg
                        {
                            nextToken();
                            ae = parseDefaultInitExp();
                            hasdefault = 1;
                        }
                        else
                        {
                            if (hasdefault)
                                error("default argument expected for `alias %s`", ai ? ai.toChars() : "");
                        }
                        goto L3;
                    }
                default:
                    {
                        stc = storageClass & (STC.in_ | STC.out_ | STC.ref_ | STC.lazy_);
                        // if stc is not a power of 2
                        if (stc & (stc - 1) && !(stc == (STC.in_ | STC.ref_)))
                            error("incompatible parameter storage classes");
                        //if ((storageClass & STC.scope_) && (storageClass & (STC.ref_ | STC.out_)))
                            //error("scope cannot be ref or out");

                        if (tpl && token.value == TOK.identifier)
                        {
                            const tv = peekNext();
                            if (tv == TOK.comma || tv == TOK.rightParentheses || tv == TOK.dotDotDot)
                            {
                                Identifier id = Identifier.generateId("__T");
                                const loc = token.loc;
                                at = new AST.TypeIdentifier(loc, id);
                                if (!*tpl)
                                    *tpl = new AST.TemplateParameters();
                                AST.TemplateParameter tp = new AST.TemplateTypeParameter(loc, id, null, null);
                                (*tpl).push(tp);

                                ai = token.ident;
                                nextToken();
                            }
                            else goto _else;
                        }
                        else
                        {
                        _else:
                            at = parseType(&ai);
                        }
                        ae = null;
                        if (token.value == TOK.assign) // = defaultArg
                        {
                            nextToken();
                            ae = parseDefaultInitExp();
                            hasdefault = 1;
                        }
                        else
                        {
                            if (hasdefault)
                                error("default argument expected for `%s`", ai ? ai.toChars() : at.toChars());
                        }
                        auto param = new AST.Parameter(storageClass, at, ai, ae, null);
                        if (udas)
                        {
                            auto a = new AST.Dsymbols();
                            auto udad = new AST.UserAttributeDeclaration(udas, a);
                            param.userAttribDecl = udad;
                        }
                        if (token.value == TOK.at)
                        {
                            AST.Expressions* exps = null;
                            StorageClass stc2 = parseAttribute(&exps);
                            if (stc2 & atAttrGroup)
                            {
                                error("`@%s` attribute for function parameter is not supported", token.toChars());
                            }
                            else
                            {
                                error("user-defined attributes cannot appear as postfixes", token.toChars());
                            }
                            if (stc2)
                                nextToken();
                        }
                        if (token.value == TOK.dotDotDot)
                        {
                            /* This is:
                             *      at ai ...
                             */
                            if (storageClass & (STC.out_ | STC.ref_))
                                error("variadic argument cannot be `out` or `ref`");
                            varargs = AST.VarArg.typesafe;
                            parameters.push(param);
                            nextToken();
                            break;
                        }
                        parameters.push(param);
                        if (token.value == TOK.comma)
                        {
                            nextToken();
                            goto L1;
                        }
                        break;
                    }
                }
                break;
            }
            break;

        L1:
        }
        check(TOK.rightParentheses);
        *pvarargs = varargs;
        return parameters;
    }

    /*************************************
     */
    private AST.EnumDeclaration parseEnum()
    {
        AST.EnumDeclaration e;
        Identifier id;
        AST.Type memtype;
        auto loc = token.loc;

        // printf("Parser::parseEnum()\n");
        nextToken();
        id = null;
        if (token.value == TOK.identifier)
        {
            id = token.ident;
            nextToken();
        }

        memtype = null;
        if (token.value == TOK.colon)
        {
            nextToken();
            int alt = 0;
            const typeLoc = token.loc;
            memtype = parseBasicType();
            memtype = parseDeclarator(memtype, &alt, null);
            checkCstyleTypeSyntax(typeLoc, memtype, alt, null);
        }

        e = new AST.EnumDeclaration(loc, id, memtype);
        if (token.value == TOK.semicolon && id)
            nextToken();
        else if (token.value == TOK.leftCurly)
        {
            bool isAnonymousEnum = !id;
            TOK prevTOK;

            //printf("enum definition\n");
            e.members = new AST.Dsymbols();
            nextToken();
            const(char)[] comment = token.blockComment;
            while (token.value != TOK.rightCurly)
            {
                /* Can take the following forms...
                 *  1. ident
                 *  2. ident = value
                 *  3. type ident = value
                 *  ... prefixed by valid attributes
                 */
                loc = token.loc;

                AST.Type type = null;
                Identifier ident = null;

                AST.Expressions* udas;
                StorageClass stc;
                AST.Expression deprecationMessage;
                enum attributeErrorMessage = "`%s` is not a valid attribute for enum members";
                while(token.value != TOK.rightCurly
                    && token.value != TOK.comma
                    && token.value != TOK.assign)
                {
                    switch(token.value)
                    {
                        case TOK.at:
                            if (StorageClass _stc = parseAttribute(&udas))
                            {
                                if (_stc == STC.disable)
                                    stc |= _stc;
                                else
                                {
                                    OutBuffer buf;
                                    AST.stcToBuffer(&buf, _stc);
                                    error(attributeErrorMessage, buf.peekChars());
                                }
                                prevTOK = token.value;
                                nextToken();
                            }
                            break;
                        case TOK.deprecated_:
                            stc |= STC.deprecated_;
                            if (!parseDeprecatedAttribute(deprecationMessage))
                            {
                                prevTOK = token.value;
                                nextToken();
                            }
                            break;
                        case TOK.identifier:
                            const tv = peekNext();
                            if (tv == TOK.assign || tv == TOK.comma || tv == TOK.rightCurly)
                            {
                                ident = token.ident;
                                type = null;
                                prevTOK = token.value;
                                nextToken();
                            }
                            else
                            {
                                goto default;
                            }
                            break;
                        default:
                            if (isAnonymousEnum)
                            {
                                type = parseType(&ident, null);
                                if (type == AST.Type.terror)
                                {
                                    type = null;
                                    prevTOK = token.value;
                                    nextToken();
                                }
                                else
                                {
                                    prevTOK = TOK.identifier;
                                }
                            }
                            else
                            {
                                error(attributeErrorMessage, token.toChars());
                                prevTOK = token.value;
                                nextToken();
                            }
                            break;
                    }
                    if (token.value == TOK.comma)
                    {
                        prevTOK = token.value;
                    }
                }

                if (type && type != AST.Type.terror)
                {
                    if (!ident)
                        error("no identifier for declarator `%s`", type.toChars());
                    if (!isAnonymousEnum)
                        error("type only allowed if anonymous enum and no enum type");
                }
                AST.Expression value;
                if (token.value == TOK.assign)
                {
                    if (prevTOK == TOK.identifier)
                    {
                        nextToken();
                        value = parseAssignExp();
                    }
                    else
                    {
                        error("assignment must be preceded by an identifier");
                        nextToken();
                    }
                }
                else
                {
                    value = null;
                    if (type && type != AST.Type.terror && isAnonymousEnum)
                        error("if type, there must be an initializer");
                }

                AST.UserAttributeDeclaration uad;
                if (udas)
                    uad = new AST.UserAttributeDeclaration(udas, null);

                AST.DeprecatedDeclaration dd;
                if (deprecationMessage)
                {
                    dd = new AST.DeprecatedDeclaration(deprecationMessage, null);
                    stc |= STC.deprecated_;
                }

                auto em = new AST.EnumMember(loc, ident, value, type, stc, uad, dd);
                e.members.push(em);

                if (token.value == TOK.rightCurly)
                {
                }
                else
                {
                    addComment(em, comment);
                    comment = null;
                    check(TOK.comma);
                }
                addComment(em, comment);
                comment = token.blockComment;

                if (token.value == TOK.endOfFile)
                {
                    error("premature end of file");
                    break;
                }
            }
            nextToken();
        }
        else
            error("enum declaration is invalid");

        //printf("-parseEnum() %s\n", e.toChars());
        return e;
    }

    /********************************
     * Parse struct, union, interface, class.
     */
    private AST.Dsymbol parseAggregate()
    {
        AST.TemplateParameters* tpl = null;
        AST.Expression constraint;
        const loc = token.loc;
        TOK tok = token.value;

        //printf("Parser::parseAggregate()\n");
        nextToken();
        Identifier id;
        if (token.value != TOK.identifier)
        {
            id = null;
        }
        else
        {
            id = token.ident;
            nextToken();

            if (token.value == TOK.leftParentheses)
            {
                // struct/class template declaration.
                tpl = parseTemplateParameterList();
                constraint = parseConstraint();
            }
        }

        // Collect base class(es)
        AST.BaseClasses* baseclasses = null;
        if (token.value == TOK.colon)
        {
            if (tok != TOK.interface_ && tok != TOK.class_)
                error("base classes are not allowed for `%s`, did you mean `;`?", Token.toChars(tok));
            nextToken();
            baseclasses = parseBaseClasses();
        }

        if (token.value == TOK.if_)
        {
            if (constraint)
                error("template constraints appear both before and after BaseClassList, put them before");
            constraint = parseConstraint();
        }
        if (constraint)
        {
            if (!id)
                error("template constraints not allowed for anonymous `%s`", Token.toChars(tok));
            if (!tpl)
                error("template constraints only allowed for templates");
        }

        AST.Dsymbols* members = null;
        if (token.value == TOK.leftCurly)
        {
            //printf("aggregate definition\n");
            const lookingForElseSave = lookingForElse;
            lookingForElse = Loc();
            nextToken();
            members = parseDeclDefs(0);
            lookingForElse = lookingForElseSave;
            if (token.value != TOK.rightCurly)
            {
                /* { */
                error("`}` expected following members in `%s` declaration at %s",
                    Token.toChars(tok), loc.toChars());
            }
            nextToken();
        }
        else if (token.value == TOK.semicolon && id)
        {
            if (baseclasses || constraint)
                error("members expected");
            nextToken();
        }
        else
        {
            error("{ } expected following `%s` declaration", Token.toChars(tok));
        }

        AST.AggregateDeclaration a;
        switch (tok)
        {
        case TOK.interface_:
            if (!id)
                error(loc, "anonymous interfaces not allowed");
            a = new AST.InterfaceDeclaration(loc, id, baseclasses);
            a.members = members;
            break;

        case TOK.class_:
            if (!id)
                error(loc, "anonymous classes not allowed");
            bool inObject = md && !md.packages && md.id == Id.object;
            a = new AST.ClassDeclaration(loc, id, baseclasses, members, inObject);
            break;

        case TOK.struct_:
            if (id)
            {
                bool inObject = md && !md.packages && md.id == Id.object;
                a = new AST.StructDeclaration(loc, id, inObject);
                a.members = members;
            }
            else
            {
                /* Anonymous structs/unions are more like attributes.
                 */
                assert(!tpl);
                return new AST.AnonDeclaration(loc, false, members);
            }
            break;

        case TOK.union_:
            if (id)
            {
                a = new AST.UnionDeclaration(loc, id);
                a.members = members;
            }
            else
            {
                /* Anonymous structs/unions are more like attributes.
                 */
                assert(!tpl);
                return new AST.AnonDeclaration(loc, true, members);
            }
            break;

        default:
            assert(0);
        }

        if (tpl)
        {
            // Wrap a template around the aggregate declaration
            auto decldefs = new AST.Dsymbols();
            decldefs.push(a);
            auto tempdecl = new AST.TemplateDeclaration(loc, id, tpl, constraint, decldefs);
            return tempdecl;
        }
        return a;
    }

    /*******************************************
     */
    private AST.BaseClasses* parseBaseClasses()
    {
        auto baseclasses = new AST.BaseClasses();

        for (; 1; nextToken())
        {
            auto b = new AST.BaseClass(parseBasicType());
            baseclasses.push(b);
            if (token.value != TOK.comma)
                break;
        }
        return baseclasses;
    }

    private AST.Dsymbols* parseImport()
    {
        auto decldefs = new AST.Dsymbols();
        Identifier aliasid = null;

        int isstatic = token.value == TOK.static_;
        if (isstatic)
            nextToken();

        //printf("Parser::parseImport()\n");
        do
        {
        L1:
            nextToken();
            if (token.value != TOK.identifier)
            {
                error("identifier expected following `import`");
                break;
            }

            const loc = token.loc;
            Identifier id = token.ident;
            AST.Identifiers* a = null;
            nextToken();
            if (!aliasid && token.value == TOK.assign)
            {
                aliasid = id;
                goto L1;
            }
            while (token.value == TOK.dot)
            {
                if (!a)
                    a = new AST.Identifiers();
                a.push(id);
                nextToken();
                if (token.value != TOK.identifier)
                {
                    error("identifier expected following `package`");
                    break;
                }
                id = token.ident;
                nextToken();
            }

            auto s = new AST.Import(loc, a, id, aliasid, isstatic);
            decldefs.push(s);

            /* Look for
             *      : alias=name, alias=name;
             * syntax.
             */
            if (token.value == TOK.colon)
            {
                do
                {
                    nextToken();
                    if (token.value != TOK.identifier)
                    {
                        error("identifier expected following `:`");
                        break;
                    }
                    Identifier _alias = token.ident;
                    Identifier name;
                    nextToken();
                    if (token.value == TOK.assign)
                    {
                        nextToken();
                        if (token.value != TOK.identifier)
                        {
                            error("identifier expected following `%s=`", _alias.toChars());
                            break;
                        }
                        name = token.ident;
                        nextToken();
                    }
                    else
                    {
                        name = _alias;
                        _alias = null;
                    }
                    s.addAlias(name, _alias);
                }
                while (token.value == TOK.comma);
                break; // no comma-separated imports of this form
            }
            aliasid = null;
        }
        while (token.value == TOK.comma);

        if (token.value == TOK.semicolon)
            nextToken();
        else
        {
            error("`;` expected");
            nextToken();
        }

        return decldefs;
    }

    AST.Type parseType(Identifier* pident = null, AST.TemplateParameters** ptpl = null)
    {
        /* Take care of the storage class prefixes that
         * serve as type attributes:
         *               const type
         *           immutable type
         *              shared type
         *               inout type
         *         inout const type
         *        shared const type
         *        shared inout type
         *  shared inout const type
         */
        StorageClass stc = 0;
        while (1)
        {
            switch (token.value)
            {
            case TOK.const_:
                if (peekNext() == TOK.leftParentheses)
                    break; // const as type constructor
                stc |= STC.const_; // const as storage class
                nextToken();
                continue;

            case TOK.immutable_:
                if (peekNext() == TOK.leftParentheses)
                    break;
                stc |= STC.immutable_;
                nextToken();
                continue;

            case TOK.shared_:
                if (peekNext() == TOK.leftParentheses)
                    break;
                stc |= STC.shared_;
                nextToken();
                continue;

            case TOK.inout_:
                if (peekNext() == TOK.leftParentheses)
                    break;
                stc |= STC.wild;
                nextToken();
                continue;

            default:
                break;
            }
            break;
        }

        const typeLoc = token.loc;

        AST.Type t;
        t = parseBasicType();

        int alt = 0;
        t = parseDeclarator(t, &alt, pident, ptpl);
        checkCstyleTypeSyntax(typeLoc, t, alt, pident ? *pident : null);

        t = t.addSTC(stc);
        return t;
    }

    private AST.Type parseBasicType(bool dontLookDotIdents = false)
    {
        AST.Type t;
        Loc loc;
        Identifier id;
        //printf("parseBasicType()\n");
        switch (token.value)
        {
        case TOK.void_:
            t = AST.Type.tvoid;
            goto LabelX;

        case TOK.int8:
            t = AST.Type.tint8;
            goto LabelX;

        case TOK.uns8:
            t = AST.Type.tuns8;
            goto LabelX;

        case TOK.int16:
            t = AST.Type.tint16;
            goto LabelX;

        case TOK.uns16:
            t = AST.Type.tuns16;
            goto LabelX;

        case TOK.int32:
            t = AST.Type.tint32;
            goto LabelX;

        case TOK.uns32:
            t = AST.Type.tuns32;
            goto LabelX;

        case TOK.int64:
            t = AST.Type.tint64;
            nextToken();
            if (token.value == TOK.int64)   // if `long long`
            {
                error("use `long` for a 64 bit integer instead of `long long`");
                nextToken();
            }
            else if (token.value == TOK.float64)   // if `long double`
            {
                error("use `real` instead of `long double`");
                t = AST.Type.tfloat80;
                nextToken();
            }
            break;

        case TOK.uns64:
            t = AST.Type.tuns64;
            goto LabelX;

        case TOK.int128:
            t = AST.Type.tint128;
            goto LabelX;

        case TOK.uns128:
            t = AST.Type.tuns128;
            goto LabelX;

        case TOK.float32:
            t = AST.Type.tfloat32;
            goto LabelX;

        case TOK.float64:
            t = AST.Type.tfloat64;
            goto LabelX;

        case TOK.float80:
            t = AST.Type.tfloat80;
            goto LabelX;

        case TOK.imaginary32:
            t = AST.Type.timaginary32;
            goto LabelX;

        case TOK.imaginary64:
            t = AST.Type.timaginary64;
            goto LabelX;

        case TOK.imaginary80:
            t = AST.Type.timaginary80;
            goto LabelX;

        case TOK.complex32:
            t = AST.Type.tcomplex32;
            goto LabelX;

        case TOK.complex64:
            t = AST.Type.tcomplex64;
            goto LabelX;

        case TOK.complex80:
            t = AST.Type.tcomplex80;
            goto LabelX;

        case TOK.bool_:
            t = AST.Type.tbool;
            goto LabelX;

        case TOK.char_:
            t = AST.Type.tchar;
            goto LabelX;

        case TOK.wchar_:
            t = AST.Type.twchar;
            goto LabelX;

        case TOK.dchar_:
            t = AST.Type.tdchar;
            goto LabelX;
        LabelX:
            nextToken();
            break;

        case TOK.this_:
        case TOK.super_:
        case TOK.identifier:
            loc = token.loc;
            id = token.ident;
            nextToken();
            if (token.value == TOK.not)
            {
                // ident!(template_arguments)
                auto tempinst = new AST.TemplateInstance(loc, id, parseTemplateArguments());
                t = parseBasicTypeStartingAt(new AST.TypeInstance(loc, tempinst), dontLookDotIdents);
            }
            else
            {
                t = parseBasicTypeStartingAt(new AST.TypeIdentifier(loc, id), dontLookDotIdents);
            }
            break;

        case TOK.mixin_:
            // https://dlang.org/spec/expression.html#mixin_types
            nextToken();
            loc = token.loc;
            if (token.value != TOK.leftParentheses)
                error("found `%s` when expecting `%s` following %s", token.toChars(), Token.toChars(TOK.leftParentheses), "`mixin`".ptr);
            auto exps = parseArguments();
            t = new AST.TypeMixin(loc, exps);
            break;

        case TOK.dot:
            // Leading . as in .foo
            t = parseBasicTypeStartingAt(new AST.TypeIdentifier(token.loc, Id.empty), dontLookDotIdents);
            break;

        case TOK.typeof_:
            // typeof(expression)
            t = parseBasicTypeStartingAt(parseTypeof(), dontLookDotIdents);
            break;

        case TOK.vector:
            t = parseVector();
            break;

        case TOK.traits:
            if (AST.TraitsExp te = cast(AST.TraitsExp) parsePrimaryExp())
                if (te.ident && te.args)
                {
                    t = new AST.TypeTraits(token.loc, te);
                    break;
                }
            t = new AST.TypeError;
            break;

        case TOK.const_:
            // const(type)
            nextToken();
            check(TOK.leftParentheses);
            t = parseType().addSTC(STC.const_);
            check(TOK.rightParentheses);
            break;

        case TOK.immutable_:
            // immutable(type)
            nextToken();
            check(TOK.leftParentheses);
            t = parseType().addSTC(STC.immutable_);
            check(TOK.rightParentheses);
            break;

        case TOK.shared_:
            // shared(type)
            nextToken();
            check(TOK.leftParentheses);
            t = parseType().addSTC(STC.shared_);
            check(TOK.rightParentheses);
            break;

        case TOK.inout_:
            // wild(type)
            nextToken();
            check(TOK.leftParentheses);
            t = parseType().addSTC(STC.wild);
            check(TOK.rightParentheses);
            break;

        default:
            error("basic type expected, not `%s`", token.toChars());
            if (token.value == TOK.else_)
                errorSupplemental(token.loc, "There's no `static else`, use `else` instead.");
            t = AST.Type.terror;
            break;
        }
        return t;
    }

    private AST.Type parseBasicTypeStartingAt(AST.TypeQualified tid, bool dontLookDotIdents)
    {
        AST.Type maybeArray = null;
        // See https://issues.dlang.org/show_bug.cgi?id=1215
        // A basic type can look like MyType (typical case), but also:
        //  MyType.T -> A type
        //  MyType[expr] -> Either a static array of MyType or a type (iif MyType is a Ttuple)
        //  MyType[expr].T -> A type.
        //  MyType[expr].T[expr] ->  Either a static array of MyType[expr].T or a type
        //                           (iif MyType[expr].T is a Ttuple)
        while (1)
        {
            switch (token.value)
            {
            case TOK.dot:
                {
                    nextToken();
                    if (token.value != TOK.identifier)
                    {
                        error("identifier expected following `.` instead of `%s`", token.toChars());
                        break;
                    }
                    if (maybeArray)
                    {
                        // This is actually a TypeTuple index, not an {a/s}array.
                        // We need to have a while loop to unwind all index taking:
                        // T[e1][e2].U   ->  T, addIndex(e1), addIndex(e2)
                        AST.Objects dimStack;
                        AST.Type t = maybeArray;
                        while (true)
                        {
                            if (t.ty == AST.Tsarray)
                            {
                                // The index expression is an Expression.
                                AST.TypeSArray a = cast(AST.TypeSArray)t;
                                dimStack.push(a.dim.syntaxCopy());
                                t = a.next.syntaxCopy();
                            }
                            else if (t.ty == AST.Taarray)
                            {
                                // The index expression is a Type. It will be interpreted as an expression at semantic time.
                                AST.TypeAArray a = cast(AST.TypeAArray)t;
                                dimStack.push(a.index.syntaxCopy());
                                t = a.next.syntaxCopy();
                            }
                            else
                            {
                                break;
                            }
                        }
                        assert(dimStack.dim > 0);
                        // We're good. Replay indices in the reverse order.
                        tid = cast(AST.TypeQualified)t;
                        while (dimStack.dim)
                        {
                            tid.addIndex(dimStack.pop());
                        }
                        maybeArray = null;
                    }
                    const loc = token.loc;
                    Identifier id = token.ident;
                    nextToken();
                    if (token.value == TOK.not)
                    {
                        auto tempinst = new AST.TemplateInstance(loc, id, parseTemplateArguments());
                        tid.addInst(tempinst);
                    }
                    else
                        tid.addIdent(id);
                    continue;
                }
            case TOK.leftBracket:
                {
                    if (dontLookDotIdents) // workaround for https://issues.dlang.org/show_bug.cgi?id=14911
                        goto Lend;

                    nextToken();
                    AST.Type t = maybeArray ? maybeArray : cast(AST.Type)tid;
                    if (token.value == TOK.rightBracket)
                    {
                        // It's a dynamic array, and we're done:
                        // T[].U does not make sense.
                        t = new AST.TypeDArray(t);
                        nextToken();
                        return t;
                    }
                    else if (isDeclaration(&token, NeedDeclaratorId.no, TOK.rightBracket, null))
                    {
                        // This can be one of two things:
                        //  1 - an associative array declaration, T[type]
                        //  2 - an associative array declaration, T[expr]
                        // These  can only be disambiguated later.
                        AST.Type index = parseType(); // [ type ]
                        maybeArray = new AST.TypeAArray(t, index);
                        check(TOK.rightBracket);
                    }
                    else
                    {
                        // This can be one of three things:
                        //  1 - an static array declaration, T[expr]
                        //  2 - a slice, T[expr .. expr]
                        //  3 - a template parameter pack index expression, T[expr].U
                        // 1 and 3 can only be disambiguated later.
                        //printf("it's type[expression]\n");
                        inBrackets++;
                        AST.Expression e = parseAssignExp(); // [ expression ]
                        if (token.value == TOK.slice)
                        {
                            // It's a slice, and we're done.
                            nextToken();
                            AST.Expression e2 = parseAssignExp(); // [ exp .. exp ]
                            t = new AST.TypeSlice(t, e, e2);
                            inBrackets--;
                            check(TOK.rightBracket);
                            return t;
                        }
                        else
                        {
                            maybeArray = new AST.TypeSArray(t, e);
                            inBrackets--;
                            check(TOK.rightBracket);
                            continue;
                        }
                    }
                    break;
                }
            default:
                goto Lend;
            }
        }
    Lend:
        return maybeArray ? maybeArray : cast(AST.Type)tid;
    }

    /******************************************
     * Parse things that follow the initial type t.
     *      t *
     *      t []
     *      t [type]
     *      t [expression]
     *      t [expression .. expression]
     *      t function
     *      t delegate
     */
    private AST.Type parseBasicType2(AST.Type t)
    {
        //printf("parseBasicType2()\n");
        while (1)
        {
            switch (token.value)
            {
            case TOK.mul:
                t = new AST.TypePointer(t);
                nextToken();
                continue;

            case TOK.leftBracket:
                // Handle []. Make sure things like
                //     int[3][1] a;
                // is (array[1] of array[3] of int)
                nextToken();
                if (token.value == TOK.rightBracket)
                {
                    t = new AST.TypeDArray(t); // []
                    nextToken();
                }
                else if (isDeclaration(&token, NeedDeclaratorId.no, TOK.rightBracket, null))
                {
                    // It's an associative array declaration
                    //printf("it's an associative array\n");
                    AST.Type index = parseType(); // [ type ]
                    t = new AST.TypeAArray(t, index);
                    check(TOK.rightBracket);
                }
                else
                {
                    //printf("it's type[expression]\n");
                    inBrackets++;
                    AST.Expression e = parseAssignExp(); // [ expression ]
                    if (token.value == TOK.slice)
                    {
                        nextToken();
                        AST.Expression e2 = parseAssignExp(); // [ exp .. exp ]
                        t = new AST.TypeSlice(t, e, e2);
                    }
                    else
                    {
                        t = new AST.TypeSArray(t, e);
                    }
                    inBrackets--;
                    check(TOK.rightBracket);
                }
                continue;

            case TOK.delegate_:
            case TOK.function_:
                {
                    // Handle delegate declaration:
                    //      t delegate(parameter list) nothrow pure
                    //      t function(parameter list) nothrow pure
                    TOK save = token.value;
                    nextToken();

                    AST.VarArg varargs;
                    AST.Parameters* parameters = parseParameters(&varargs);

                    StorageClass stc = parsePostfix(STC.undefined_, null);
                    auto tf = new AST.TypeFunction(AST.ParameterList(parameters, varargs), t, linkage, stc);
                    if (stc & (STC.const_ | STC.immutable_ | STC.shared_ | STC.wild | STC.return_))
                    {
                        if (save == TOK.function_)
                            error("`const`/`immutable`/`shared`/`inout`/`return` attributes are only valid for non-static member functions");
                        else
                            tf = cast(AST.TypeFunction)tf.addSTC(stc);
                    }
                    t = save == TOK.delegate_ ? new AST.TypeDelegate(tf) : new AST.TypePointer(tf); // pointer to function
                    continue;
                }
            default:
                return t;
            }
            assert(0);
        }
        assert(0);
    }

    private AST.Type parseDeclarator(AST.Type t, int* palt, Identifier* pident, AST.TemplateParameters** tpl = null, StorageClass storageClass = 0, int* pdisable = null, AST.Expressions** pudas = null)
    {
        //printf("parseDeclarator(tpl = %p)\n", tpl);
        t = parseBasicType2(t);
        AST.Type ts;
        switch (token.value)
        {
        case TOK.identifier:
            if (pident)
                *pident = token.ident;
            else
                error("unexpected identifier `%s` in declarator", token.ident.toChars());
            ts = t;
            nextToken();
            break;

        case TOK.leftParentheses:
            {
                // like: T (*fp)();
                // like: T ((*fp))();
                if (peekNext() == TOK.mul || peekNext() == TOK.leftParentheses)
                {
                    /* Parse things with parentheses around the identifier, like:
                     *  int (*ident[3])[]
                     * although the D style would be:
                     *  int[]*[3] ident
                     */
                    *palt |= 1;
                    nextToken();
                    ts = parseDeclarator(t, palt, pident);
                    check(TOK.rightParentheses);
                    break;
                }
                ts = t;

                Token* peekt = &token;
                /* Completely disallow C-style things like:
                 *   T (a);
                 * Improve error messages for the common bug of a missing return type
                 * by looking to see if (a) looks like a parameter list.
                 */
                if (isParameters(&peekt))
                {
                    error("function declaration without return type. (Note that constructors are always named `this`)");
                }
                else
                    error("unexpected `(` in declarator");
                break;
            }
        default:
            ts = t;
            break;
        }

        // parse DeclaratorSuffixes
        while (1)
        {
            switch (token.value)
            {
                static if (CARRAYDECL)
                {
                    /* Support C style array syntax:
                     *   int ident[]
                     * as opposed to D-style:
                     *   int[] ident
                     */
                case TOK.leftBracket:
                    {
                        // This is the old C-style post [] syntax.
                        AST.TypeNext ta;
                        nextToken();
                        if (token.value == TOK.rightBracket)
                        {
                            // It's a dynamic array
                            ta = new AST.TypeDArray(t); // []
                            nextToken();
                            *palt |= 2;
                        }
                        else if (isDeclaration(&token, NeedDeclaratorId.no, TOK.rightBracket, null))
                        {
                            // It's an associative array
                            //printf("it's an associative array\n");
                            AST.Type index = parseType(); // [ type ]
                            check(TOK.rightBracket);
                            ta = new AST.TypeAArray(t, index);
                            *palt |= 2;
                        }
                        else
                        {
                            //printf("It's a static array\n");
                            AST.Expression e = parseAssignExp(); // [ expression ]
                            ta = new AST.TypeSArray(t, e);
                            check(TOK.rightBracket);
                            *palt |= 2;
                        }

                        /* Insert ta into
                         *   ts -> ... -> t
                         * so that
                         *   ts -> ... -> ta -> t
                         */
                        AST.Type* pt;
                        for (pt = &ts; *pt != t; pt = &(cast(AST.TypeNext)*pt).next)
                        {
                        }
                        *pt = ta;
                        continue;
                    }
                }
            case TOK.leftParentheses:
                {
                    if (tpl)
                    {
                        Token* tk = peekPastParen(&token);
                        if (tk.value == TOK.leftParentheses)
                        {
                            /* Look ahead to see if this is (...)(...),
                             * i.e. a function template declaration
                             */
                            //printf("function template declaration\n");

                            // Gather template parameter list
                            *tpl = parseTemplateParameterList();
                        }
                        else if (tk.value == TOK.assign)
                        {
                            /* or (...) =,
                             * i.e. a variable template declaration
                             */
                            //printf("variable template declaration\n");
                            *tpl = parseTemplateParameterList();
                            break;
                        }
                    }

                    AST.VarArg varargs;
                    AST.Parameters* parameters = parseParameters(&varargs);

                    /* Parse const/immutable/shared/inout/nothrow/pure/return postfix
                     */
                    // merge prefix storage classes
                    StorageClass stc = parsePostfix(storageClass, pudas);

                    AST.Type tf = new AST.TypeFunction(AST.ParameterList(parameters, varargs), t, linkage, stc);
                    tf = tf.addSTC(stc);
                    if (pdisable)
                        *pdisable = stc & STC.disable ? 1 : 0;

                    /* Insert tf into
                     *   ts -> ... -> t
                     * so that
                     *   ts -> ... -> tf -> t
                     */
                    AST.Type* pt;
                    for (pt = &ts; *pt != t; pt = &(cast(AST.TypeNext)*pt).next)
                    {
                    }
                    *pt = tf;
                    break;
                }
            default:
                break;
            }
            break;
        }
        return ts;
    }

    private void parseStorageClasses(ref StorageClass storage_class, ref LINK link,
        ref bool setAlignment, ref AST.Expression ealign, ref AST.Expressions* udas)
    {
        StorageClass stc;
        bool sawLinkage = false; // seen a linkage declaration

        while (1)
        {
            switch (token.value)
            {
            case TOK.const_:
                if (peekNext() == TOK.leftParentheses)
                    break; // const as type constructor
                stc = STC.const_; // const as storage class
                goto L1;

            case TOK.immutable_:
                if (peekNext() == TOK.leftParentheses)
                    break;
                stc = STC.immutable_;
                goto L1;

            case TOK.shared_:
                if (peekNext() == TOK.leftParentheses)
                    break;
                stc = STC.shared_;
                goto L1;

            case TOK.inout_:
                if (peekNext() == TOK.leftParentheses)
                    break;
                stc = STC.wild;
                goto L1;

            case TOK.static_:
                stc = STC.static_;
                goto L1;

            case TOK.final_:
                stc = STC.final_;
                goto L1;

            case TOK.auto_:
                stc = STC.auto_;
                goto L1;

            case TOK.scope_:
                stc = STC.scope_;
                goto L1;

            case TOK.override_:
                stc = STC.override_;
                goto L1;

            case TOK.abstract_:
                stc = STC.abstract_;
                goto L1;

            case TOK.synchronized_:
                stc = STC.synchronized_;
                goto L1;

            case TOK.deprecated_:
                stc = STC.deprecated_;
                goto L1;

            case TOK.nothrow_:
                stc = STC.nothrow_;
                goto L1;

            case TOK.pure_:
                stc = STC.pure_;
                goto L1;

            case TOK.ref_:
                stc = STC.ref_;
                goto L1;

            case TOK.gshared:
                stc = STC.gshared;
                goto L1;

            case TOK.enum_:
                {
                    const tv = peekNext();
                    if (tv == TOK.leftCurly || tv == TOK.colon)
                        break;
                    if (tv == TOK.identifier)
                    {
                        const nextv = peekNext2();
                        if (nextv == TOK.leftCurly || nextv == TOK.colon || nextv == TOK.semicolon)
                            break;
                    }
                    stc = STC.manifest;
                    goto L1;
                }

            case TOK.at:
                {
                    stc = parseAttribute(&udas);
                    if (stc)
                        goto L1;
                    continue;
                }
            L1:
                storage_class = appendStorageClass(storage_class, stc);
                nextToken();
                continue;

            case TOK.extern_:
                {
                    if (peekNext() != TOK.leftParentheses)
                    {
                        stc = STC.extern_;
                        goto L1;
                    }

                    if (sawLinkage)
                        error("redundant linkage declaration");
                    sawLinkage = true;
                    AST.Identifiers* idents = null;
                    AST.Expressions* identExps = null;
                    CPPMANGLE cppmangle;
                    bool cppMangleOnly = false;
                    link = parseLinkage(&idents, &identExps, cppmangle, cppMangleOnly);
                    if (idents || identExps)
                    {
                        error("C++ name spaces not allowed here");
                    }
                    if (cppmangle != CPPMANGLE.def)
                    {
                        error("C++ mangle declaration not allowed here");
                    }
                    continue;
                }
            case TOK.align_:
                {
                    nextToken();
                    setAlignment = true;
                    if (token.value == TOK.leftParentheses)
                    {
                        nextToken();
                        ealign = parseExpression();
                        check(TOK.rightParentheses);
                    }
                    continue;
                }
            default:
                break;
            }
            break;
        }
    }

    /**********************************
     * Parse Declarations.
     * These can be:
     *      1. declarations at global/class level
     *      2. declarations at statement level
     * Return array of Declaration *'s.
     */
    private AST.Dsymbols* parseDeclarations(bool autodecl, PrefixAttributes!AST* pAttrs, const(char)* comment)
    {
        StorageClass storage_class = STC.undefined_;
        TOK tok = TOK.reserved;
        LINK link = linkage;
        bool setAlignment = false;
        AST.Expression ealign;
        AST.Expressions* udas = null;

        //printf("parseDeclarations() %s\n", token.toChars());
        if (!comment)
            comment = token.blockComment.ptr;

        if (token.value == TOK.alias_)
        {
            const loc = token.loc;
            tok = token.value;
            nextToken();

            /* Look for:
             *   alias identifier this;
             */
            if (token.value == TOK.identifier && peekNext() == TOK.this_)
            {
                auto s = new AST.AliasThis(loc, token.ident);
                nextToken();
                check(TOK.this_);
                check(TOK.semicolon);
                auto a = new AST.Dsymbols();
                a.push(s);
                addComment(s, comment);
                return a;
            }
            version (none)
            {
                /* Look for:
                 *  alias this = identifier;
                 */
                if (token.value == TOK.this_ && peekNext() == TOK.assign && peekNext2() == TOK.identifier)
                {
                    check(TOK.this_);
                    check(TOK.assign);
                    auto s = new AliasThis(loc, token.ident);
                    nextToken();
                    check(TOK.semicolon);
                    auto a = new Dsymbols();
                    a.push(s);
                    addComment(s, comment);
                    return a;
                }
            }
            /* Look for:
             *  alias identifier = type;
             *  alias identifier(...) = type;
             */
            if (token.value == TOK.identifier && hasOptionalParensThen(peek(&token), TOK.assign))
            {
                auto a = new AST.Dsymbols();
                while (1)
                {
                    auto ident = token.ident;
                    nextToken();
                    AST.TemplateParameters* tpl = null;
                    if (token.value == TOK.leftParentheses)
                        tpl = parseTemplateParameterList();
                    check(TOK.assign);

                    bool hasParsedAttributes;
                    void parseAttributes()
                    {
                        if (hasParsedAttributes) // only parse once
                            return;
                        hasParsedAttributes = true;
                        udas = null;
                        storage_class = STC.undefined_;
                        link = linkage;
                        setAlignment = false;
                        ealign = null;
                        parseStorageClasses(storage_class, link, setAlignment, ealign, udas);
                    }

                    if (token.value == TOK.at)
                        parseAttributes;

                    AST.Declaration v;
                    AST.Dsymbol s;

                    // try to parse function type:
                    // TypeCtors? BasicType ( Parameters ) MemberFunctionAttributes
                    bool attributesAppended;
                    const StorageClass funcStc = parseTypeCtor();
                    Token* tlu = &token;
                    Token* tk;
                    if (token.value != TOK.function_ &&
                        token.value != TOK.delegate_ &&
                        isBasicType(&tlu) && tlu &&
                        tlu.value == TOK.leftParentheses)
                    {
                        AST.VarArg vargs;
                        AST.Type tret = parseBasicType();
                        AST.Parameters* prms = parseParameters(&vargs);
                        AST.ParameterList pl = AST.ParameterList(prms, vargs);

                        parseAttributes();
                        if (udas)
                            error("user-defined attributes not allowed for `alias` declarations");

                        attributesAppended = true;
                        storage_class = appendStorageClass(storage_class, funcStc);
                        AST.Type tf = new AST.TypeFunction(pl, tret, link, storage_class);
                        v = new AST.AliasDeclaration(loc, ident, tf);
                    }
                    else if (token.value == TOK.function_ ||
                        token.value == TOK.delegate_ ||
                        token.value == TOK.leftParentheses &&
                            skipAttributes(peekPastParen(&token), &tk) &&
                            (tk.value == TOK.goesTo || tk.value == TOK.leftCurly) ||
                        token.value == TOK.leftCurly ||
                        token.value == TOK.identifier && peekNext() == TOK.goesTo ||
                        token.value == TOK.ref_ && peekNext() == TOK.leftParentheses &&
                            skipAttributes(peekPastParen(peek(&token)), &tk) &&
                            (tk.value == TOK.goesTo || tk.value == TOK.leftCurly)
                       )
                    {
                        // function (parameters) { statements... }
                        // delegate (parameters) { statements... }
                        // (parameters) { statements... }
                        // (parameters) => expression
                        // { statements... }
                        // identifier => expression
                        // ref (parameters) { statements... }
                        // ref (parameters) => expression

                        s = parseFunctionLiteral();

                        if (udas !is null)
                        {
                            if (storage_class != 0)
                                error("Cannot put a storage-class in an alias declaration.");
                            // parseAttributes shouldn't have set these variables
                            assert(link == linkage && !setAlignment && ealign is null);
                            auto tpl_ = cast(AST.TemplateDeclaration) s;
                            assert(tpl_ !is null && tpl_.members.dim == 1);
                            auto fd = cast(AST.FuncLiteralDeclaration) (*tpl_.members)[0];
                            auto tf = cast(AST.TypeFunction) fd.type;
                            assert(tf.parameterList.parameters.dim > 0);
                            auto as = new AST.Dsymbols();
                            (*tf.parameterList.parameters)[0].userAttribDecl = new AST.UserAttributeDeclaration(udas, as);
                        }

                        v = new AST.AliasDeclaration(loc, ident, s);
                    }
                    else
                    {
                        parseAttributes();
                        // StorageClasses type
                        if (udas)
                            error("user-defined attributes not allowed for `%s` declarations", Token.toChars(tok));

                        auto t = parseType();
                        v = new AST.AliasDeclaration(loc, ident, t);
                    }
                    if (!attributesAppended)
                        storage_class = appendStorageClass(storage_class, funcStc);
                    v.storage_class = storage_class;

                    s = v;
                    if (tpl)
                    {
                        auto a2 = new AST.Dsymbols();
                        a2.push(s);
                        auto tempdecl = new AST.TemplateDeclaration(loc, ident, tpl, null, a2);
                        s = tempdecl;
                    }
                    if (link != linkage)
                    {
                        auto a2 = new AST.Dsymbols();
                        a2.push(s);
                        s = new AST.LinkDeclaration(link, a2);
                    }
                    a.push(s);

                    switch (token.value)
                    {
                    case TOK.semicolon:
                        nextToken();
                        addComment(s, comment);
                        break;

                    case TOK.comma:
                        nextToken();
                        addComment(s, comment);
                        if (token.value != TOK.identifier)
                        {
                            error("identifier expected following comma, not `%s`", token.toChars());
                            break;
                        }
                        if (peekNext() != TOK.assign && peekNext() != TOK.leftParentheses)
                        {
                            error("`=` expected following identifier");
                            nextToken();
                            break;
                        }
                        continue;

                    default:
                        error("semicolon expected to close `%s` declaration", Token.toChars(tok));
                        break;
                    }
                    break;
                }
                return a;
            }

            // alias StorageClasses type ident;
        }

        AST.Type ts;

        if (!autodecl)
        {
            parseStorageClasses(storage_class, link, setAlignment, ealign, udas);

            if (token.value == TOK.enum_)
            {
                AST.Dsymbol d = parseEnum();
                auto a = new AST.Dsymbols();
                a.push(d);

                if (udas)
                {
                    d = new AST.UserAttributeDeclaration(udas, a);
                    a = new AST.Dsymbols();
                    a.push(d);
                }

                addComment(d, comment);
                return a;
            }
            if (token.value == TOK.struct_ ||
                     token.value == TOK.union_ ||
                     token.value == TOK.class_ ||
                     token.value == TOK.interface_)
            {
                AST.Dsymbol s = parseAggregate();
                auto a = new AST.Dsymbols();
                a.push(s);

                if (storage_class)
                {
                    s = new AST.StorageClassDeclaration(storage_class, a);
                    a = new AST.Dsymbols();
                    a.push(s);
                }
                if (setAlignment)
                {
                    s = new AST.AlignDeclaration(s.loc, ealign, a);
                    a = new AST.Dsymbols();
                    a.push(s);
                }
                if (link != linkage)
                {
                    s = new AST.LinkDeclaration(link, a);
                    a = new AST.Dsymbols();
                    a.push(s);
                }
                if (udas)
                {
                    s = new AST.UserAttributeDeclaration(udas, a);
                    a = new AST.Dsymbols();
                    a.push(s);
                }

                addComment(s, comment);
                return a;
            }

            /* Look for auto initializers:
             *  storage_class identifier = initializer;
             *  storage_class identifier(...) = initializer;
             */
            if ((storage_class || udas) && token.value == TOK.identifier && hasOptionalParensThen(peek(&token), TOK.assign))
            {
                AST.Dsymbols* a = parseAutoDeclarations(storage_class, comment);
                if (udas)
                {
                    AST.Dsymbol s = new AST.UserAttributeDeclaration(udas, a);
                    a = new AST.Dsymbols();
                    a.push(s);
                }
                return a;
            }

            /* Look for return type inference for template functions.
             */
            {
                Token* tk;
                if ((storage_class || udas) && token.value == TOK.identifier && skipParens(peek(&token), &tk) &&
                    skipAttributes(tk, &tk) &&
                    (tk.value == TOK.leftParentheses || tk.value == TOK.leftCurly || tk.value == TOK.in_ || tk.value == TOK.out_ ||
                     tk.value == TOK.do_ || tk.value == TOK.identifier && tk.ident == Id._body))
                {
                    version (none)
                    {
                        // This deprecation has been disabled for the time being, see PR10763
                        // @@@DEPRECATED@@@
                        // https://github.com/dlang/DIPs/blob/1f5959abe482b1f9094f6484a7d0a3ade77fc2fc/DIPs/accepted/DIP1003.md
                        // Deprecated in 2.091 - Can be removed from 2.101
                        if (tk.value == TOK.identifier && tk.ident == Id._body)
                            deprecation("Usage of the `body` keyword is deprecated. Use `do` instead.");
                    }
                    ts = null;
                }
                else
                {
                    ts = parseBasicType();
                    ts = parseBasicType2(ts);
                }
            }
        }

        if (pAttrs)
        {
            storage_class |= pAttrs.storageClass;
            //pAttrs.storageClass = STC.undefined_;
        }

        AST.Type tfirst = null;
        auto a = new AST.Dsymbols();

        while (1)
        {
            AST.TemplateParameters* tpl = null;
            int disable;
            int alt = 0;

            const loc = token.loc;
            Identifier ident = null;

            auto t = parseDeclarator(ts, &alt, &ident, &tpl, storage_class, &disable, &udas);
            assert(t);
            if (!tfirst)
                tfirst = t;
            else if (t != tfirst)
                error("multiple declarations must have the same type, not `%s` and `%s`", tfirst.toChars(), t.toChars());

            bool isThis = (t.ty == AST.Tident && (cast(AST.TypeIdentifier)t).ident == Id.This && token.value == TOK.assign);
            if (ident)
                checkCstyleTypeSyntax(loc, t, alt, ident);
            else if (!isThis && (t != AST.Type.terror))
                error("no identifier for declarator `%s`", t.toChars());

            if (tok == TOK.alias_)
            {
                AST.Declaration v;
                AST.Initializer _init = null;

                /* Aliases can no longer have multiple declarators, storage classes,
                 * linkages, or auto declarations.
                 * These never made any sense, anyway.
                 * The code below needs to be fixed to reject them.
                 * The grammar has already been fixed to preclude them.
                 */

                if (udas)
                    error("user-defined attributes not allowed for `%s` declarations", Token.toChars(tok));

                if (token.value == TOK.assign)
                {
                    nextToken();
                    _init = parseInitializer();
                }
                if (_init)
                {
                    if (isThis)
                        error("cannot use syntax `alias this = %s`, use `alias %s this` instead", _init.toChars(), _init.toChars());
                    else
                        error("alias cannot have initializer");
                }
                v = new AST.AliasDeclaration(loc, ident, t);

                v.storage_class = storage_class;
                if (pAttrs)
                {
                    /* AliasDeclaration distinguish @safe, @system, @trusted attributes
                     * on prefix and postfix.
                     *   @safe alias void function() FP1;
                     *   alias @safe void function() FP2;    // FP2 is not @safe
                     *   alias void function() @safe FP3;
                     */
                    pAttrs.storageClass &= STC.safeGroup;
                }
                AST.Dsymbol s = v;

                if (link != linkage)
                {
                    auto ax = new AST.Dsymbols();
                    ax.push(v);
                    s = new AST.LinkDeclaration(link, ax);
                }
                a.push(s);
                switch (token.value)
                {
                case TOK.semicolon:
                    nextToken();
                    addComment(s, comment);
                    break;

                case TOK.comma:
                    nextToken();
                    addComment(s, comment);
                    continue;

                default:
                    error("semicolon expected to close `%s` declaration", Token.toChars(tok));
                    break;
                }
            }
            else if (t.ty == AST.Tfunction)
            {
                AST.Expression constraint = null;
                //printf("%s funcdecl t = %s, storage_class = x%lx\n", loc.toChars(), t.toChars(), storage_class);
                auto f = new AST.FuncDeclaration(loc, Loc.initial, ident, storage_class | (disable ? STC.disable : 0), t);
                if (pAttrs)
                    pAttrs.storageClass = STC.undefined_;
                if (tpl)
                    constraint = parseConstraint();
                AST.Dsymbol s = parseContracts(f);
                auto tplIdent = s.ident;

                if (link != linkage)
                {
                    auto ax = new AST.Dsymbols();
                    ax.push(s);
                    s = new AST.LinkDeclaration(link, ax);
                }
                if (udas)
                {
                    auto ax = new AST.Dsymbols();
                    ax.push(s);
                    s = new AST.UserAttributeDeclaration(udas, ax);
                }

                /* A template parameter list means it's a function template
                 */
                if (tpl)
                {
                    // Wrap a template around the function declaration
                    auto decldefs = new AST.Dsymbols();
                    decldefs.push(s);
                    auto tempdecl = new AST.TemplateDeclaration(loc, tplIdent, tpl, constraint, decldefs);
                    s = tempdecl;

                    if (storage_class & STC.static_)
                    {
                        assert(f.storage_class & STC.static_);
                        f.storage_class &= ~STC.static_;
                        auto ax = new AST.Dsymbols();
                        ax.push(s);
                        s = new AST.StorageClassDeclaration(STC.static_, ax);
                    }
                }
                a.push(s);
                addComment(s, comment);
            }
            else if (ident)
            {
                AST.Initializer _init = null;
                if (token.value == TOK.assign)
                {
                    nextToken();
                    _init = parseInitializer();
                }

                auto v = new AST.VarDeclaration(loc, t, ident, _init);
                v.storage_class = storage_class;
                if (pAttrs)
                    pAttrs.storageClass = STC.undefined_;

                AST.Dsymbol s = v;

                if (tpl && _init)
                {
                    auto a2 = new AST.Dsymbols();
                    a2.push(s);
                    auto tempdecl = new AST.TemplateDeclaration(loc, ident, tpl, null, a2, 0);
                    s = tempdecl;
                }
                if (setAlignment)
                {
                    auto ax = new AST.Dsymbols();
                    ax.push(s);
                    s = new AST.AlignDeclaration(v.loc, ealign, ax);
                }
                if (link != linkage)
                {
                    auto ax = new AST.Dsymbols();
                    ax.push(s);
                    s = new AST.LinkDeclaration(link, ax);
                }
                if (udas)
                {
                    auto ax = new AST.Dsymbols();
                    ax.push(s);
                    s = new AST.UserAttributeDeclaration(udas, ax);
                }
                a.push(s);
                switch (token.value)
                {
                case TOK.semicolon:
                    nextToken();
                    addComment(s, comment);
                    break;

                case TOK.comma:
                    nextToken();
                    addComment(s, comment);
                    continue;

                default:
                    error("semicolon expected, not `%s`", token.toChars());
                    break;
                }
            }
            break;
        }
        return a;
    }

    private AST.Dsymbol parseFunctionLiteral()
    {
        const loc = token.loc;
        AST.TemplateParameters* tpl = null;
        AST.Parameters* parameters = null;
        AST.VarArg varargs = AST.VarArg.none;
        AST.Type tret = null;
        StorageClass stc = 0;
        TOK save = TOK.reserved;

        switch (token.value)
        {
        case TOK.function_:
        case TOK.delegate_:
            save = token.value;
            nextToken();
            if (token.value == TOK.ref_)
            {
                // function ref (parameters) { statements... }
                // delegate ref (parameters) { statements... }
                stc = STC.ref_;
                nextToken();
            }
            if (token.value != TOK.leftParentheses && token.value != TOK.leftCurly)
            {
                // function type (parameters) { statements... }
                // delegate type (parameters) { statements... }
                tret = parseBasicType();
                tret = parseBasicType2(tret); // function return type
            }

            if (token.value == TOK.leftParentheses)
            {
                // function (parameters) { statements... }
                // delegate (parameters) { statements... }
            }
            else
            {
                // function { statements... }
                // delegate { statements... }
                break;
            }
            goto case TOK.leftParentheses;

        case TOK.ref_:
            {
                // ref (parameters) => expression
                // ref (parameters) { statements... }
                stc = STC.ref_;
                nextToken();
                goto case TOK.leftParentheses;
            }
        case TOK.leftParentheses:
            {
                // (parameters) => expression
                // (parameters) { statements... }
                parameters = parseParameters(&varargs, &tpl);
                stc = parsePostfix(stc, null);
                if (StorageClass modStc = stc & STC.TYPECTOR)
                {
                    if (save == TOK.function_)
                    {
                        OutBuffer buf;
                        AST.stcToBuffer(&buf, modStc);
                        error("function literal cannot be `%s`", buf.peekChars());
                    }
                    else
                        save = TOK.delegate_;
                }
                break;
            }
        case TOK.leftCurly:
            // { statements... }
            break;

        case TOK.identifier:
            {
                // identifier => expression
                parameters = new AST.Parameters();
                Identifier id = Identifier.generateId("__T");
                AST.Type t = new AST.TypeIdentifier(loc, id);
                parameters.push(new AST.Parameter(0, t, token.ident, null, null));

                tpl = new AST.TemplateParameters();
                AST.TemplateParameter tp = new AST.TemplateTypeParameter(loc, id, null, null);
                tpl.push(tp);

                nextToken();
                break;
            }
        default:
            assert(0);
        }

        auto tf = new AST.TypeFunction(AST.ParameterList(parameters, varargs), tret, linkage, stc);
        tf = cast(AST.TypeFunction)tf.addSTC(stc);
        auto fd = new AST.FuncLiteralDeclaration(loc, Loc.initial, tf, save, null);

        if (token.value == TOK.goesTo)
        {
            check(TOK.goesTo);
            const returnloc = token.loc;
            AST.Expression ae = parseAssignExp();
            fd.fbody = new AST.ReturnStatement(returnloc, ae);
            fd.endloc = token.loc;
        }
        else
        {
            parseContracts(fd);
        }

        if (tpl)
        {
            // Wrap a template around function fd
            auto decldefs = new AST.Dsymbols();
            decldefs.push(fd);
            return new AST.TemplateDeclaration(fd.loc, fd.ident, tpl, null, decldefs, false, true);
        }
        return fd;
    }

    /*****************************************
     * Parse contracts following function declaration.
     */
    private AST.FuncDeclaration parseContracts(AST.FuncDeclaration f)
    {
        LINK linksave = linkage;

        bool literal = f.isFuncLiteralDeclaration() !is null;

        // The following is irrelevant, as it is overridden by sc.linkage in
        // TypeFunction::semantic
        linkage = LINK.d; // nested functions have D linkage
        bool requireDo = false;
    L1:
        switch (token.value)
        {
        case TOK.leftCurly:
            if (requireDo)
                error("missing `do { ... }` after `in` or `out`");
            f.fbody = parseStatement(ParseStatementFlags.semi);
            f.endloc = endloc;
            break;

        case TOK.identifier:
            if (token.ident == Id._body)
            {
                version (none)
                {
                    // This deprecation has been disabled for the time being, see PR10763
                    // @@@DEPRECATED@@@
                    // https://github.com/dlang/DIPs/blob/1f5959abe482b1f9094f6484a7d0a3ade77fc2fc/DIPs/accepted/DIP1003.md
                    // Deprecated in 2.091 - Can be removed from 2.101
                    deprecation("Usage of the `body` keyword is deprecated. Use `do` instead.");
                }
                goto case TOK.do_;
            }
            goto default;

        case TOK.do_:
            nextToken();
            f.fbody = parseStatement(ParseStatementFlags.curly);
            f.endloc = endloc;
            break;

            version (none)
            {
                // Do we want this for function declarations, so we can do:
                // int x, y, foo(), z;
            case TOK.comma:
                nextToken();
                continue;
            }

        case TOK.in_:
            // in { statements... }
            // in (expression)
            auto loc = token.loc;
            nextToken();
            if (!f.frequires)
            {
                f.frequires = new AST.Statements;
            }
            if (token.value == TOK.leftParentheses)
            {
                nextToken();
                AST.Expression e = parseAssignExp(), msg = null;
                if (token.value == TOK.comma)
                {
                    nextToken();
                    if (token.value != TOK.rightParentheses)
                    {
                        msg = parseAssignExp();
                        if (token.value == TOK.comma)
                            nextToken();
                    }
                }
                check(TOK.rightParentheses);
                e = new AST.AssertExp(loc, e, msg);
                f.frequires.push(new AST.ExpStatement(loc, e));
                requireDo = false;
            }
            else
            {
                f.frequires.push(parseStatement(ParseStatementFlags.curly | ParseStatementFlags.scope_));
                requireDo = true;
            }
            goto L1;

        case TOK.out_:
            // out { statements... }
            // out (; expression)
            // out (identifier) { statements... }
            // out (identifier; expression)
            auto loc = token.loc;
            nextToken();
            if (!f.fensures)
            {
                f.fensures = new AST.Ensures;
            }
            Identifier id = null;
            if (token.value != TOK.leftCurly)
            {
                check(TOK.leftParentheses);
                if (token.value != TOK.identifier && token.value != TOK.semicolon)
                    error("`(identifier) { ... }` or `(identifier; expression)` following `out` expected, not `%s`", token.toChars());
                if (token.value != TOK.semicolon)
                {
                    id = token.ident;
                    nextToken();
                }
                if (token.value == TOK.semicolon)
                {
                    nextToken();
                    AST.Expression e = parseAssignExp(), msg = null;
                    if (token.value == TOK.comma)
                    {
                        nextToken();
                        if (token.value != TOK.rightParentheses)
                        {
                            msg = parseAssignExp();
                            if (token.value == TOK.comma)
                                nextToken();
                        }
                    }
                    check(TOK.rightParentheses);
                    e = new AST.AssertExp(loc, e, msg);
                    f.fensures.push(AST.Ensure(id, new AST.ExpStatement(loc, e)));
                    requireDo = false;
                    goto L1;
                }
                check(TOK.rightParentheses);
            }
            f.fensures.push(AST.Ensure(id, parseStatement(ParseStatementFlags.curly | ParseStatementFlags.scope_)));
            requireDo = true;
            goto L1;

        case TOK.semicolon:
            if (!literal)
            {
                // https://issues.dlang.org/show_bug.cgi?id=15799
                // Semicolon becomes a part of function declaration
                // only when 'do' is not required
                if (!requireDo)
                    nextToken();
                break;
            }
            goto default;

        default:
            if (literal)
            {
                const(char)* sbody = requireDo ? "do " : "";
                error("missing `%s{ ... }` for function literal", sbody);
            }
            else if (!requireDo) // allow contracts even with no body
            {
                TOK t = token.value;
                if (t == TOK.const_ || t == TOK.immutable_ || t == TOK.inout_ || t == TOK.return_ ||
                        t == TOK.shared_ || t == TOK.nothrow_ || t == TOK.pure_)
                    error("'%s' cannot be placed after a template constraint", token.toChars);
                else if (t == TOK.at)
                    error("attributes cannot be placed after a template constraint");
                else if (t == TOK.if_)
                    error("cannot use function constraints for non-template functions. Use `static if` instead");
                else
                    error("semicolon expected following function declaration");
            }
            break;
        }
        if (literal && !f.fbody)
        {
            // Set empty function body for error recovery
            f.fbody = new AST.CompoundStatement(Loc.initial, cast(AST.Statement)null);
        }

        linkage = linksave;

        return f;
    }

    /*****************************************
     */
    private void checkDanglingElse(Loc elseloc)
    {
        if (token.value != TOK.else_ && token.value != TOK.catch_ && token.value != TOK.finally_ && lookingForElse.linnum != 0)
        {
            warning(elseloc, "else is dangling, add { } after condition at %s", lookingForElse.toChars());
        }
    }

    private void checkCstyleTypeSyntax(Loc loc, AST.Type t, int alt, Identifier ident)
    {
        if (!alt)
            return;

        const(char)* sp = !ident ? "" : " ";
        const(char)* s = !ident ? "" : ident.toChars();
        error(loc, "instead of C-style syntax, use D-style `%s%s%s`", t.toChars(), sp, s);
    }

    /*****************************************
     * Determines additional argument types for parseForeach.
     */
    private template ParseForeachArgs(bool isStatic, bool isDecl)
    {
        static alias Seq(T...) = T;
        static if(isDecl)
        {
            alias ParseForeachArgs = Seq!(AST.Dsymbol*);
        }
        else
        {
            alias ParseForeachArgs = Seq!();
        }
    }
    /*****************************************
     * Determines the result type for parseForeach.
     */
    private template ParseForeachRet(bool isStatic, bool isDecl)
    {
        static if(!isStatic)
        {
            alias ParseForeachRet = AST.Statement;
        }
        else static if(isDecl)
        {
            alias ParseForeachRet = AST.StaticForeachDeclaration;
        }
        else
        {
            alias ParseForeachRet = AST.StaticForeachStatement;
        }
    }
    /*****************************************
     * Parses `foreach` statements, `static foreach` statements and
     * `static foreach` declarations.  The template parameter
     * `isStatic` is true, iff a `static foreach` should be parsed.
     * If `isStatic` is true, `isDecl` can be true to indicate that a
     * `static foreach` declaration should be parsed.
     */
    private ParseForeachRet!(isStatic, isDecl) parseForeach(bool isStatic, bool isDecl)(Loc loc, ParseForeachArgs!(isStatic, isDecl) args)
    {
        static if(isDecl)
        {
            static assert(isStatic);
        }
        static if(isStatic)
        {
            nextToken();
            static if(isDecl) auto pLastDecl = args[0];
        }

        TOK op = token.value;

        nextToken();
        check(TOK.leftParentheses);

        auto parameters = new AST.Parameters();
        while (1)
        {
            Identifier ai = null;
            AST.Type at;

            StorageClass storageClass = 0;
            StorageClass stc = 0;
        Lagain:
            if (stc)
            {
                storageClass = appendStorageClass(storageClass, stc);
                nextToken();
            }
            switch (token.value)
            {
                case TOK.ref_:
                    stc = STC.ref_;
                    goto Lagain;

                case TOK.enum_:
                    stc = STC.manifest;
                    goto Lagain;

                case TOK.alias_:
                    storageClass = appendStorageClass(storageClass, STC.alias_);
                    nextToken();
                    break;

                case TOK.const_:
                    if (peekNext() != TOK.leftParentheses)
                    {
                        stc = STC.const_;
                        goto Lagain;
                    }
                    break;

                case TOK.immutable_:
                    if (peekNext() != TOK.leftParentheses)
                    {
                        stc = STC.immutable_;
                        goto Lagain;
                    }
                    break;

                case TOK.shared_:
                    if (peekNext() != TOK.leftParentheses)
                    {
                        stc = STC.shared_;
                        goto Lagain;
                    }
                    break;

                case TOK.inout_:
                    if (peekNext() != TOK.leftParentheses)
                    {
                        stc = STC.wild;
                        goto Lagain;
                    }
                    break;

                default:
                    break;
            }
            if (token.value == TOK.identifier)
            {
                const tv = peekNext();
                if (tv == TOK.comma || tv == TOK.semicolon)
                {
                    ai = token.ident;
                    at = null; // infer argument type
                    nextToken();
                    goto Larg;
                }
            }
            at = parseType(&ai);
            if (!ai)
                error("no identifier for declarator `%s`", at.toChars());
        Larg:
            auto p = new AST.Parameter(storageClass, at, ai, null, null);
            parameters.push(p);
            if (token.value == TOK.comma)
            {
                nextToken();
                continue;
            }
            break;
        }
        check(TOK.semicolon);

        AST.Expression aggr = parseExpression();
        if (token.value == TOK.slice && parameters.dim == 1)
        {
            AST.Parameter p = (*parameters)[0];
            nextToken();
            AST.Expression upr = parseExpression();
            check(TOK.rightParentheses);
            Loc endloc;
            static if (!isDecl)
            {
                AST.Statement _body = parseStatement(0, null, &endloc);
            }
            else
            {
                AST.Statement _body = null;
            }
            auto rangefe = new AST.ForeachRangeStatement(loc, op, p, aggr, upr, _body, endloc);
            static if (!isStatic)
            {
                return rangefe;
            }
            else static if(isDecl)
            {
                return new AST.StaticForeachDeclaration(new AST.StaticForeach(loc, null, rangefe), parseBlock(pLastDecl));
            }
            else
            {
                return new AST.StaticForeachStatement(loc, new AST.StaticForeach(loc, null, rangefe));
            }
        }
        else
        {
            check(TOK.rightParentheses);
            Loc endloc;
            static if (!isDecl)
            {
                AST.Statement _body = parseStatement(0, null, &endloc);
            }
            else
            {
                AST.Statement _body = null;
            }
            auto aggrfe = new AST.ForeachStatement(loc, op, parameters, aggr, _body, endloc);
            static if(!isStatic)
            {
                return aggrfe;
            }
            else static if(isDecl)
            {
                return new AST.StaticForeachDeclaration(new AST.StaticForeach(loc, aggrfe, null), parseBlock(pLastDecl));
            }
            else
            {
                return new AST.StaticForeachStatement(loc, new AST.StaticForeach(loc, aggrfe, null));
            }
        }

    }

    /*****************************************
     * Input:
     *      flags   PSxxxx
     * Output:
     *      pEndloc if { ... statements ... }, store location of closing brace, otherwise loc of last token of statement
     */
    AST.Statement parseStatement(int flags, const(char)** endPtr = null, Loc* pEndloc = null)
    {
        AST.Statement s;
        AST.Condition cond;
        AST.Statement ifbody;
        AST.Statement elsebody;
        bool isfinal;
        const loc = token.loc;

        //printf("parseStatement()\n");
        if (flags & ParseStatementFlags.curly && token.value != TOK.leftCurly)
            error("statement expected to be `{ }`, not `%s`", token.toChars());

        switch (token.value)
        {
        case TOK.identifier:
            {
                /* A leading identifier can be a declaration, label, or expression.
                 * The easiest case to check first is label:
                 */
                if (peekNext() == TOK.colon)
                {
                    if (peekNext2() == TOK.colon)
                    {
                        // skip ident::
                        nextToken();
                        nextToken();
                        nextToken();
                        error("use `.` for member lookup, not `::`");
                        break;
                    }
                    // It's a label
                    Identifier ident = token.ident;
                    nextToken();
                    nextToken();
                    if (token.value == TOK.rightCurly)
                        s = null;
                    else if (token.value == TOK.leftCurly)
                        s = parseStatement(ParseStatementFlags.curly | ParseStatementFlags.scope_);
                    else
                        s = parseStatement(ParseStatementFlags.semiOk);
                    s = new AST.LabelStatement(loc, ident, s);
                    break;
                }
                goto case TOK.dot;
            }
        case TOK.dot:
        case TOK.typeof_:
        case TOK.vector:
        case TOK.traits:
            /* https://issues.dlang.org/show_bug.cgi?id=15163
             * If tokens can be handled as
             * old C-style declaration or D expression, prefer the latter.
             */
            if (isDeclaration(&token, NeedDeclaratorId.mustIfDstyle, TOK.reserved, null))
                goto Ldeclaration;
            goto Lexp;

        case TOK.assert_:
        case TOK.this_:
        case TOK.super_:
        case TOK.int32Literal:
        case TOK.uns32Literal:
        case TOK.int64Literal:
        case TOK.uns64Literal:
        case TOK.int128Literal:
        case TOK.uns128Literal:
        case TOK.float32Literal:
        case TOK.float64Literal:
        case TOK.float80Literal:
        case TOK.imaginary32Literal:
        case TOK.imaginary64Literal:
        case TOK.imaginary80Literal:
        case TOK.charLiteral:
        case TOK.wcharLiteral:
        case TOK.dcharLiteral:
        case TOK.null_:
        case TOK.true_:
        case TOK.false_:
        case TOK.string_:
        case TOK.hexadecimalString:
        case TOK.leftParentheses:
        case TOK.cast_:
        case TOK.mul:
        case TOK.min:
        case TOK.add:
        case TOK.tilde:
        case TOK.not:
        case TOK.plusPlus:
        case TOK.minusMinus:
        case TOK.new_:
        case TOK.delete_:
        case TOK.delegate_:
        case TOK.function_:
        case TOK.typeid_:
        case TOK.is_:
        case TOK.leftBracket:
        case TOK.file:
        case TOK.fileFullPath:
        case TOK.line:
        case TOK.moduleString:
        case TOK.functionString:
        case TOK.prettyFunction:
        Lexp:
            {
                AST.Expression exp = parseExpression();
                check(TOK.semicolon, "statement");
                s = new AST.ExpStatement(loc, exp);
                break;
            }
        case TOK.static_:
            {
                // Look ahead to see if it's static assert() or static if()
                const tv = peekNext();
                if (tv == TOK.assert_)
                {
                    s = new AST.StaticAssertStatement(parseStaticAssert());
                    break;
                }
                if (tv == TOK.if_)
                {
                    cond = parseStaticIfCondition();
                    goto Lcondition;
                }
                if (tv == TOK.foreach_ || tv == TOK.foreach_reverse_)
                {
                    s = parseForeach!(true,false)(loc);
                    if (flags & ParseStatementFlags.scope_)
                        s = new AST.ScopeStatement(loc, s, token.loc);
                    break;
                }
                if (tv == TOK.import_)
                {
                    AST.Dsymbols* imports = parseImport();
                    s = new AST.ImportStatement(loc, imports);
                    if (flags & ParseStatementFlags.scope_)
                        s = new AST.ScopeStatement(loc, s, token.loc);
                    break;
                }
                goto Ldeclaration;
            }
        case TOK.final_:
            if (peekNext() == TOK.switch_)
            {
                nextToken();
                isfinal = true;
                goto Lswitch;
            }
            goto Ldeclaration;

        case TOK.wchar_:
        case TOK.dchar_:
        case TOK.bool_:
        case TOK.char_:
        case TOK.int8:
        case TOK.uns8:
        case TOK.int16:
        case TOK.uns16:
        case TOK.int32:
        case TOK.uns32:
        case TOK.int64:
        case TOK.uns64:
        case TOK.int128:
        case TOK.uns128:
        case TOK.float32:
        case TOK.float64:
        case TOK.float80:
        case TOK.imaginary32:
        case TOK.imaginary64:
        case TOK.imaginary80:
        case TOK.complex32:
        case TOK.complex64:
        case TOK.complex80:
        case TOK.void_:
            // bug 7773: int.max is always a part of expression
            if (peekNext() == TOK.dot)
                goto Lexp;
            if (peekNext() == TOK.leftParentheses)
                goto Lexp;
            goto case;

        case TOK.alias_:
        case TOK.const_:
        case TOK.auto_:
        case TOK.abstract_:
        case TOK.extern_:
        case TOK.align_:
        case TOK.immutable_:
        case TOK.shared_:
        case TOK.inout_:
        case TOK.deprecated_:
        case TOK.nothrow_:
        case TOK.pure_:
        case TOK.ref_:
        case TOK.gshared:
        case TOK.at:
        case TOK.struct_:
        case TOK.union_:
        case TOK.class_:
        case TOK.interface_:
        Ldeclaration:
            {
                AST.Dsymbols* a = parseDeclarations(false, null, null);
                if (a.dim > 1)
                {
                    auto as = new AST.Statements();
                    as.reserve(a.dim);
                    foreach (i; 0 .. a.dim)
                    {
                        AST.Dsymbol d = (*a)[i];
                        s = new AST.ExpStatement(loc, d);
                        as.push(s);
                    }
                    s = new AST.CompoundDeclarationStatement(loc, as);
                }
                else if (a.dim == 1)
                {
                    AST.Dsymbol d = (*a)[0];
                    s = new AST.ExpStatement(loc, d);
                }
                else
                    s = new AST.ExpStatement(loc, cast(AST.Expression)null);
                if (flags & ParseStatementFlags.scope_)
                    s = new AST.ScopeStatement(loc, s, token.loc);
                break;
            }
        case TOK.enum_:
            {
                /* Determine if this is a manifest constant declaration,
                 * or a conventional enum.
                 */
                AST.Dsymbol d;
                const tv = peekNext();
                if (tv == TOK.leftCurly || tv == TOK.colon)
                    d = parseEnum();
                else if (tv != TOK.identifier)
                    goto Ldeclaration;
                else
                {
                    const nextv = peekNext2();
                    if (nextv == TOK.leftCurly || nextv == TOK.colon || nextv == TOK.semicolon)
                        d = parseEnum();
                    else
                        goto Ldeclaration;
                }
                s = new AST.ExpStatement(loc, d);
                if (flags & ParseStatementFlags.scope_)
                    s = new AST.ScopeStatement(loc, s, token.loc);
                break;
            }
        case TOK.mixin_:
            {
                if (isDeclaration(&token, NeedDeclaratorId.mustIfDstyle, TOK.reserved, null))
                    goto Ldeclaration;
                if (peekNext() == TOK.leftParentheses)
                {
                    // mixin(string)
                    AST.Expression e = parseAssignExp();
                    check(TOK.semicolon);
                    if (e.op == TOK.mixin_)
                    {
                        AST.CompileExp cpe = cast(AST.CompileExp)e;
                        s = new AST.CompileStatement(loc, cpe.exps);
                    }
                    else
                    {
                        s = new AST.ExpStatement(loc, e);
                    }
                    break;
                }
                AST.Dsymbol d = parseMixin();
                s = new AST.ExpStatement(loc, d);
                if (flags & ParseStatementFlags.scope_)
                    s = new AST.ScopeStatement(loc, s, token.loc);
                break;
            }
        case TOK.leftCurly:
            {
                const lookingForElseSave = lookingForElse;
                lookingForElse = Loc.initial;

                nextToken();
                //if (token.value == TOK.semicolon)
                //    error("use `{ }` for an empty statement, not `;`");
                auto statements = new AST.Statements();
                while (token.value != TOK.rightCurly && token.value != TOK.endOfFile)
                {
                    statements.push(parseStatement(ParseStatementFlags.semi | ParseStatementFlags.curlyScope));
                }
                if (endPtr)
                    *endPtr = token.ptr;
                endloc = token.loc;
                if (pEndloc)
                {
                    *pEndloc = token.loc;
                    pEndloc = null; // don't set it again
                }
                s = new AST.CompoundStatement(loc, statements);
                if (flags & (ParseStatementFlags.scope_ | ParseStatementFlags.curlyScope))
                    s = new AST.ScopeStatement(loc, s, token.loc);
                check(TOK.rightCurly, "compound statement");
                lookingForElse = lookingForElseSave;
                break;
            }
        case TOK.while_:
            {
                nextToken();
                check(TOK.leftParentheses);
                AST.Expression condition = parseExpression();
                check(TOK.rightParentheses);
                Loc endloc;
                AST.Statement _body = parseStatement(ParseStatementFlags.scope_, null, &endloc);
                s = new AST.WhileStatement(loc, condition, _body, endloc);
                break;
            }
        case TOK.semicolon:
            if (!(flags & ParseStatementFlags.semiOk))
            {
                if (flags & ParseStatementFlags.semi)
                    deprecation("use `{ }` for an empty statement, not `;`");
                else
                    error("use `{ }` for an empty statement, not `;`");
            }
            nextToken();
            s = new AST.ExpStatement(loc, cast(AST.Expression)null);
            break;

        case TOK.do_:
            {
                AST.Statement _body;
                AST.Expression condition;

                nextToken();
                const lookingForElseSave = lookingForElse;
                lookingForElse = Loc.initial;
                _body = parseStatement(ParseStatementFlags.scope_);
                lookingForElse = lookingForElseSave;
                check(TOK.while_);
                check(TOK.leftParentheses);
                condition = parseExpression();
                check(TOK.rightParentheses);
                if (token.value == TOK.semicolon)
                    nextToken();
                else
                    error("terminating `;` required after do-while statement");
                s = new AST.DoStatement(loc, _body, condition, token.loc);
                break;
            }
        case TOK.for_:
            {
                AST.Statement _init;
                AST.Expression condition;
                AST.Expression increment;

                nextToken();
                check(TOK.leftParentheses);
                if (token.value == TOK.semicolon)
                {
                    _init = null;
                    nextToken();
                }
                else
                {
                    const lookingForElseSave = lookingForElse;
                    lookingForElse = Loc.initial;
                    _init = parseStatement(0);
                    lookingForElse = lookingForElseSave;
                }
                if (token.value == TOK.semicolon)
                {
                    condition = null;
                    nextToken();
                }
                else
                {
                    condition = parseExpression();
                    check(TOK.semicolon, "`for` condition");
                }
                if (token.value == TOK.rightParentheses)
                {
                    increment = null;
                    nextToken();
                }
                else
                {
                    increment = parseExpression();
                    check(TOK.rightParentheses);
                }
                Loc endloc;
                AST.Statement _body = parseStatement(ParseStatementFlags.scope_, null, &endloc);
                s = new AST.ForStatement(loc, _init, condition, increment, _body, endloc);
                break;
            }
        case TOK.foreach_:
        case TOK.foreach_reverse_:
            {
                s = parseForeach!(false,false)(loc);
                break;
            }
        case TOK.if_:
            {
                AST.Parameter param = null;
                AST.Expression condition;

                nextToken();
                check(TOK.leftParentheses);

                StorageClass storageClass = 0;
                StorageClass stc = 0;
            LagainStc:
                if (stc)
                {
                    storageClass = appendStorageClass(storageClass, stc);
                    nextToken();
                }
                switch (token.value)
                {
                case TOK.ref_:
                    stc = STC.ref_;
                    goto LagainStc;

                case TOK.auto_:
                    stc = STC.auto_;
                    goto LagainStc;

                case TOK.const_:
                    if (peekNext() != TOK.leftParentheses)
                    {
                        stc = STC.const_;
                        goto LagainStc;
                    }
                    break;

                case TOK.immutable_:
                    if (peekNext() != TOK.leftParentheses)
                    {
                        stc = STC.immutable_;
                        goto LagainStc;
                    }
                    break;

                case TOK.shared_:
                    if (peekNext() != TOK.leftParentheses)
                    {
                        stc = STC.shared_;
                        goto LagainStc;
                    }
                    break;

                case TOK.inout_:
                    if (peekNext() != TOK.leftParentheses)
                    {
                        stc = STC.wild;
                        goto LagainStc;
                    }
                    break;

                default:
                    break;
                }
                auto n = peek(&token);
                if (storageClass != 0 && token.value == TOK.identifier &&
                    n.value != TOK.assign && n.value != TOK.identifier)
                {
                    error("found `%s` while expecting `=` or identifier", n.toChars());
                }
                else if (storageClass != 0 && token.value == TOK.identifier && n.value == TOK.assign)
                {
                    Identifier ai = token.ident;
                    AST.Type at = null; // infer parameter type
                    nextToken();
                    check(TOK.assign);
                    param = new AST.Parameter(storageClass, at, ai, null, null);
                }
                else if (isDeclaration(&token, NeedDeclaratorId.must, TOK.assign, null))
                {
                    Identifier ai;
                    AST.Type at = parseType(&ai);
                    check(TOK.assign);
                    param = new AST.Parameter(storageClass, at, ai, null, null);
                }

                condition = parseExpression();
                check(TOK.rightParentheses);
                {
                    const lookingForElseSave = lookingForElse;
                    lookingForElse = loc;
                    ifbody = parseStatement(ParseStatementFlags.scope_);
                    lookingForElse = lookingForElseSave;
                }
                if (token.value == TOK.else_)
                {
                    const elseloc = token.loc;
                    nextToken();
                    elsebody = parseStatement(ParseStatementFlags.scope_);
                    checkDanglingElse(elseloc);
                }
                else
                    elsebody = null;
                if (condition && ifbody)
                    s = new AST.IfStatement(loc, param, condition, ifbody, elsebody, token.loc);
                else
                    s = null; // don't propagate parsing errors
                break;
            }

        case TOK.else_:
            error("found `else` without a corresponding `if`, `version` or `debug` statement");
            goto Lerror;

        case TOK.scope_:
            if (peekNext() != TOK.leftParentheses)
                goto Ldeclaration; // scope used as storage class
            nextToken();
            check(TOK.leftParentheses);
            if (token.value != TOK.identifier)
            {
                error("scope identifier expected");
                goto Lerror;
            }
            else
            {
                TOK t = TOK.onScopeExit;
                Identifier id = token.ident;
                if (id == Id.exit)
                    t = TOK.onScopeExit;
                else if (id == Id.failure)
                    t = TOK.onScopeFailure;
                else if (id == Id.success)
                    t = TOK.onScopeSuccess;
                else
                    error("valid scope identifiers are `exit`, `failure`, or `success`, not `%s`", id.toChars());
                nextToken();
                check(TOK.rightParentheses);
                AST.Statement st = parseStatement(ParseStatementFlags.scope_);
                s = new AST.ScopeGuardStatement(loc, t, st);
                break;
            }

        case TOK.debug_:
            nextToken();
            if (token.value == TOK.assign)
            {
                error("debug conditions can only be declared at module scope");
                nextToken();
                nextToken();
                goto Lerror;
            }
            cond = parseDebugCondition();
            goto Lcondition;

        case TOK.version_:
            nextToken();
            if (token.value == TOK.assign)
            {
                error("version conditions can only be declared at module scope");
                nextToken();
                nextToken();
                goto Lerror;
            }
            cond = parseVersionCondition();
            goto Lcondition;

        Lcondition:
            {
                const lookingForElseSave = lookingForElse;
                lookingForElse = loc;
                ifbody = parseStatement(0);
                lookingForElse = lookingForElseSave;
            }
            elsebody = null;
            if (token.value == TOK.else_)
            {
                const elseloc = token.loc;
                nextToken();
                elsebody = parseStatement(0);
                checkDanglingElse(elseloc);
            }
            s = new AST.ConditionalStatement(loc, cond, ifbody, elsebody);
            if (flags & ParseStatementFlags.scope_)
                s = new AST.ScopeStatement(loc, s, token.loc);
            break;

        case TOK.pragma_:
            {
                Identifier ident;
                AST.Expressions* args = null;
                AST.Statement _body;

                nextToken();
                check(TOK.leftParentheses);
                if (token.value != TOK.identifier)
                {
                    error("`pragma(identifier)` expected");
                    goto Lerror;
                }
                ident = token.ident;
                nextToken();
                if (token.value == TOK.comma && peekNext() != TOK.rightParentheses)
                    args = parseArguments(); // pragma(identifier, args...);
                else
                    check(TOK.rightParentheses); // pragma(identifier);
                if (token.value == TOK.semicolon)
                {
                    nextToken();
                    _body = null;
                }
                else
                    _body = parseStatement(ParseStatementFlags.semi);
                s = new AST.PragmaStatement(loc, ident, args, _body);
                break;
            }
        case TOK.switch_:
            isfinal = false;
            goto Lswitch;

        Lswitch:
            {
                nextToken();
                check(TOK.leftParentheses);
                AST.Expression condition = parseExpression();
                check(TOK.rightParentheses);
                AST.Statement _body = parseStatement(ParseStatementFlags.scope_);
                s = new AST.SwitchStatement(loc, condition, _body, isfinal);
                break;
            }
        case TOK.case_:
            {
                AST.Expression exp;
                AST.Expressions cases; // array of Expression's
                AST.Expression last = null;

                while (1)
                {
                    nextToken();
                    exp = parseAssignExp();
                    cases.push(exp);
                    if (token.value != TOK.comma)
                        break;
                }
                check(TOK.colon);

                /* case exp: .. case last:
                 */
                if (token.value == TOK.slice)
                {
                    if (cases.dim > 1)
                        error("only one `case` allowed for start of case range");
                    nextToken();
                    check(TOK.case_);
                    last = parseAssignExp();
                    check(TOK.colon);
                }

                if (flags & ParseStatementFlags.curlyScope)
                {
                    auto statements = new AST.Statements();
                    while (token.value != TOK.case_ && token.value != TOK.default_ && token.value != TOK.endOfFile && token.value != TOK.rightCurly)
                    {
                        statements.push(parseStatement(ParseStatementFlags.semi | ParseStatementFlags.curlyScope));
                    }
                    s = new AST.CompoundStatement(loc, statements);
                }
                else
                {
                    s = parseStatement(ParseStatementFlags.semi);
                }
                s = new AST.ScopeStatement(loc, s, token.loc);

                if (last)
                {
                    s = new AST.CaseRangeStatement(loc, exp, last, s);
                }
                else
                {
                    // Keep cases in order by building the case statements backwards
                    for (size_t i = cases.dim; i; i--)
                    {
                        exp = cases[i - 1];
                        s = new AST.CaseStatement(loc, exp, s);
                    }
                }
                break;
            }
        case TOK.default_:
            {
                nextToken();
                check(TOK.colon);

                if (flags & ParseStatementFlags.curlyScope)
                {
                    auto statements = new AST.Statements();
                    while (token.value != TOK.case_ && token.value != TOK.default_ && token.value != TOK.endOfFile && token.value != TOK.rightCurly)
                    {
                        statements.push(parseStatement(ParseStatementFlags.semi | ParseStatementFlags.curlyScope));
                    }
                    s = new AST.CompoundStatement(loc, statements);
                }
                else
                    s = parseStatement(ParseStatementFlags.semi);
                s = new AST.ScopeStatement(loc, s, token.loc);
                s = new AST.DefaultStatement(loc, s);
                break;
            }
        case TOK.return_:
            {
                AST.Expression exp;
                nextToken();
                exp = token.value == TOK.semicolon ? null : parseExpression();
                check(TOK.semicolon, "`return` statement");
                s = new AST.ReturnStatement(loc, exp);
                break;
            }
        case TOK.break_:
            {
                Identifier ident;
                nextToken();
                ident = null;
                if (token.value == TOK.identifier)
                {
                    ident = token.ident;
                    nextToken();
                }
                check(TOK.semicolon, "`break` statement");
                s = new AST.BreakStatement(loc, ident);
                break;
            }
        case TOK.continue_:
            {
                Identifier ident;
                nextToken();
                ident = null;
                if (token.value == TOK.identifier)
                {
                    ident = token.ident;
                    nextToken();
                }
                check(TOK.semicolon, "`continue` statement");
                s = new AST.ContinueStatement(loc, ident);
                break;
            }
        case TOK.goto_:
            {
                Identifier ident;
                nextToken();
                if (token.value == TOK.default_)
                {
                    nextToken();
                    s = new AST.GotoDefaultStatement(loc);
                }
                else if (token.value == TOK.case_)
                {
                    AST.Expression exp = null;
                    nextToken();
                    if (token.value != TOK.semicolon)
                        exp = parseExpression();
                    s = new AST.GotoCaseStatement(loc, exp);
                }
                else
                {
                    if (token.value != TOK.identifier)
                    {
                        error("identifier expected following `goto`");
                        ident = null;
                    }
                    else
                    {
                        ident = token.ident;
                        nextToken();
                    }
                    s = new AST.GotoStatement(loc, ident);
                }
                check(TOK.semicolon, "`goto` statement");
                break;
            }
        case TOK.synchronized_:
            {
                AST.Expression exp;
                AST.Statement _body;

                Token* t = peek(&token);
                if (skipAttributes(t, &t) && t.value == TOK.class_)
                    goto Ldeclaration;

                nextToken();
                if (token.value == TOK.leftParentheses)
                {
                    nextToken();
                    exp = parseExpression();
                    check(TOK.rightParentheses);
                }
                else
                    exp = null;
                _body = parseStatement(ParseStatementFlags.scope_);
                s = new AST.SynchronizedStatement(loc, exp, _body);
                break;
            }
        case TOK.with_:
            {
                AST.Expression exp;
                AST.Statement _body;
                Loc endloc = loc;

                nextToken();
                check(TOK.leftParentheses);
                exp = parseExpression();
                check(TOK.rightParentheses);
                _body = parseStatement(ParseStatementFlags.scope_, null, &endloc);
                s = new AST.WithStatement(loc, exp, _body, endloc);
                break;
            }
        case TOK.try_:
            {
                AST.Statement _body;
                AST.Catches* catches = null;
                AST.Statement finalbody = null;

                nextToken();
                const lookingForElseSave = lookingForElse;
                lookingForElse = Loc.initial;
                _body = parseStatement(ParseStatementFlags.scope_);
                lookingForElse = lookingForElseSave;
                while (token.value == TOK.catch_)
                {
                    AST.Statement handler;
                    AST.Catch c;
                    AST.Type t;
                    Identifier id;
                    const catchloc = token.loc;

                    nextToken();
                    if (token.value == TOK.leftCurly || token.value != TOK.leftParentheses)
                    {
                        t = null;
                        id = null;
                    }
                    else
                    {
                        check(TOK.leftParentheses);
                        id = null;
                        t = parseType(&id);
                        check(TOK.rightParentheses);
                    }
                    handler = parseStatement(0);
                    c = new AST.Catch(catchloc, t, id, handler);
                    if (!catches)
                        catches = new AST.Catches();
                    catches.push(c);
                }

                if (token.value == TOK.finally_)
                {
                    nextToken();
                    finalbody = parseStatement(ParseStatementFlags.scope_);
                }

                s = _body;
                if (!catches && !finalbody)
                    error("`catch` or `finally` expected following `try`");
                else
                {
                    if (catches)
                        s = new AST.TryCatchStatement(loc, _body, catches);
                    if (finalbody)
                        s = new AST.TryFinallyStatement(loc, s, finalbody);
                }
                break;
            }
        case TOK.throw_:
            {
                AST.Expression exp;
                nextToken();
                exp = parseExpression();
                check(TOK.semicolon, "`throw` statement");
                s = new AST.ThrowStatement(loc, exp);
                break;
            }

        case TOK.asm_:
            {
                // Parse the asm block into a sequence of AsmStatements,
                // each AsmStatement is one instruction.
                // Separate out labels.
                // Defer parsing of AsmStatements until semantic processing.

                Loc labelloc;

                nextToken();
                StorageClass stc = parsePostfix(STC.undefined_, null);
                if (stc & (STC.const_ | STC.immutable_ | STC.shared_ | STC.wild))
                    error("`const`/`immutable`/`shared`/`inout` attributes are not allowed on `asm` blocks");

                check(TOK.leftCurly);
                Token* toklist = null;
                Token** ptoklist = &toklist;
                Identifier label = null;
                auto statements = new AST.Statements();
                size_t nestlevel = 0;
                while (1)
                {
                    switch (token.value)
                    {
                    case TOK.identifier:
                        if (!toklist)
                        {
                            // Look ahead to see if it is a label
                            if (peekNext() == TOK.colon)
                            {
                                // It's a label
                                label = token.ident;
                                labelloc = token.loc;
                                nextToken();
                                nextToken();
                                continue;
                            }
                        }
                        goto default;

                    case TOK.leftCurly:
                        ++nestlevel;
                        goto default;

                    case TOK.rightCurly:
                        if (nestlevel > 0)
                        {
                            --nestlevel;
                            goto default;
                        }
                        if (toklist || label)
                        {
                            error("`asm` statements must end in `;`");
                        }
                        break;

                    case TOK.semicolon:
                        if (nestlevel != 0)
                            error("mismatched number of curly brackets");

                        s = null;
                        if (toklist || label)
                        {
                            // Create AsmStatement from list of tokens we've saved
                            s = new AST.AsmStatement(token.loc, toklist);
                            toklist = null;
                            ptoklist = &toklist;
                            if (label)
                            {
                                s = new AST.LabelStatement(labelloc, label, s);
                                label = null;
                            }
                            statements.push(s);
                        }
                        nextToken();
                        continue;

                    case TOK.endOfFile:
                        /* { */
                        error("matching `}` expected, not end of file");
                        goto Lerror;

                    default:
                        *ptoklist = allocateToken();
                        memcpy(*ptoklist, &token, Token.sizeof);
                        ptoklist = &(*ptoklist).next;
                        *ptoklist = null;
                        nextToken();
                        continue;
                    }
                    break;
                }
                s = new AST.CompoundAsmStatement(loc, statements, stc);
                nextToken();
                break;
            }
        case TOK.import_:
            {
                /* https://issues.dlang.org/show_bug.cgi?id=16088
                 *
                 * At this point it can either be an
                 * https://dlang.org/spec/grammar.html#ImportExpression
                 * or an
                 * https://dlang.org/spec/grammar.html#ImportDeclaration.
                 * See if the next token after `import` is a `(`; if so,
                 * then it is an import expression.
                 */
                if (peekNext() == TOK.leftParentheses)
                {
                    AST.Expression e = parseExpression();
                    check(TOK.semicolon);
                    s = new AST.ExpStatement(loc, e);
                }
                else
                {
                    AST.Dsymbols* imports = parseImport();
                    s = new AST.ImportStatement(loc, imports);
                    if (flags & ParseStatementFlags.scope_)
                        s = new AST.ScopeStatement(loc, s, token.loc);
                }
                break;
            }
        case TOK.template_:
            {
                AST.Dsymbol d = parseTemplateDeclaration();
                s = new AST.ExpStatement(loc, d);
                break;
            }
        default:
            error("found `%s` instead of statement", token.toChars());
            goto Lerror;

        Lerror:
            while (token.value != TOK.rightCurly && token.value != TOK.semicolon && token.value != TOK.endOfFile)
                nextToken();
            if (token.value == TOK.semicolon)
                nextToken();
            s = null;
            break;
        }
        if (pEndloc)
            *pEndloc = prevloc;
        return s;
    }

    /*****************************************
     * Parse initializer for variable declaration.
     */
    private AST.Initializer parseInitializer()
    {
        AST.StructInitializer _is;
        AST.ArrayInitializer ia;
        AST.ExpInitializer ie;
        AST.Expression e;
        Identifier id;
        AST.Initializer value;
        int comma;
        const loc = token.loc;
        Token* t;
        int braces;
        int brackets;

        switch (token.value)
        {
        case TOK.leftCurly:
            /* Scan ahead to discern between a struct initializer and
             * parameterless function literal.
             *
             * We'll scan the topmost curly bracket level for statement-related
             * tokens, thereby ruling out a struct initializer.  (A struct
             * initializer which itself contains function literals may have
             * statements at nested curly bracket levels.)
             *
             * It's important that this function literal check not be
             * pendantic, otherwise a function having the slightest syntax
             * error would emit confusing errors when we proceed to parse it
             * as a struct initializer.
             *
             * The following two ambiguous cases will be treated as a struct
             * initializer (best we can do without type info):
             *     {}
             *     {{statements...}}  - i.e. it could be struct initializer
             *        with one function literal, or function literal having an
             *        extra level of curly brackets
             * If a function literal is intended in these cases (unlikely),
             * source can use a more explicit function literal syntax
             * (e.g. prefix with "()" for empty parameter list).
             */
            braces = 1;
            for (t = peek(&token); 1; t = peek(t))
            {
                switch (t.value)
                {
                /* Look for a semicolon or keyword of statements which don't
                 * require a semicolon (typically containing BlockStatement).
                 * Tokens like "else", "catch", etc. are omitted where the
                 * leading token of the statement is sufficient.
                 */
                case TOK.asm_:
                case TOK.class_:
                case TOK.debug_:
                case TOK.enum_:
                case TOK.if_:
                case TOK.interface_:
                case TOK.pragma_:
                case TOK.scope_:
                case TOK.semicolon:
                case TOK.struct_:
                case TOK.switch_:
                case TOK.synchronized_:
                case TOK.try_:
                case TOK.union_:
                case TOK.version_:
                case TOK.while_:
                case TOK.with_:
                    if (braces == 1)
                        goto Lexpression;
                    continue;

                case TOK.leftCurly:
                    braces++;
                    continue;

                case TOK.rightCurly:
                    if (--braces == 0)
                        break;
                    continue;

                case TOK.endOfFile:
                    break;

                default:
                    continue;
                }
                break;
            }

            _is = new AST.StructInitializer(loc);
            nextToken();
            comma = 2;
            while (1)
            {
                switch (token.value)
                {
                case TOK.identifier:
                    if (comma == 1)
                        error("comma expected separating field initializers");
                    t = peek(&token);
                    if (t.value == TOK.colon)
                    {
                        id = token.ident;
                        nextToken();
                        nextToken(); // skip over ':'
                    }
                    else
                    {
                        id = null;
                    }
                    value = parseInitializer();
                    _is.addInit(id, value);
                    comma = 1;
                    continue;

                case TOK.comma:
                    if (comma == 2)
                        error("expression expected, not `,`");
                    nextToken();
                    comma = 2;
                    continue;

                case TOK.rightCurly: // allow trailing comma's
                    nextToken();
                    break;

                case TOK.endOfFile:
                    error("found end of file instead of initializer");
                    break;

                default:
                    if (comma == 1)
                        error("comma expected separating field initializers");
                    value = parseInitializer();
                    _is.addInit(null, value);
                    comma = 1;
                    continue;
                    //error("found `%s` instead of field initializer", token.toChars());
                    //break;
                }
                break;
            }
            return _is;

        case TOK.leftBracket:
            /* Scan ahead to see if it is an array initializer or
             * an expression.
             * If it ends with a ';' ',' or '}', it is an array initializer.
             */
            brackets = 1;
            for (t = peek(&token); 1; t = peek(t))
            {
                switch (t.value)
                {
                case TOK.leftBracket:
                    brackets++;
                    continue;

                case TOK.rightBracket:
                    if (--brackets == 0)
                    {
                        t = peek(t);
                        if (t.value != TOK.semicolon && t.value != TOK.comma && t.value != TOK.rightBracket && t.value != TOK.rightCurly)
                            goto Lexpression;
                        break;
                    }
                    continue;

                case TOK.endOfFile:
                    break;

                default:
                    continue;
                }
                break;
            }

            ia = new AST.ArrayInitializer(loc);
            nextToken();
            comma = 2;
            while (1)
            {
                switch (token.value)
                {
                default:
                    if (comma == 1)
                    {
                        error("comma expected separating array initializers, not `%s`", token.toChars());
                        nextToken();
                        break;
                    }
                    e = parseAssignExp();
                    if (!e)
                        break;
                    if (token.value == TOK.colon)
                    {
                        nextToken();
                        value = parseInitializer();
                    }
                    else
                    {
                        value = new AST.ExpInitializer(e.loc, e);
                        e = null;
                    }
                    ia.addInit(e, value);
                    comma = 1;
                    continue;

                case TOK.leftCurly:
                case TOK.leftBracket:
                    if (comma == 1)
                        error("comma expected separating array initializers, not `%s`", token.toChars());
                    value = parseInitializer();
                    if (token.value == TOK.colon)
                    {
                        nextToken();
                        if (auto ei = value.isExpInitializer())
                        {
                            e = ei.exp;
                            value = parseInitializer();
                        }
                        else
                            error("initializer expression expected following colon, not `%s`", token.toChars());
                    }
                    else
                        e = null;
                    ia.addInit(e, value);
                    comma = 1;
                    continue;

                case TOK.comma:
                    if (comma == 2)
                        error("expression expected, not `,`");
                    nextToken();
                    comma = 2;
                    continue;

                case TOK.rightBracket: // allow trailing comma's
                    nextToken();
                    break;

                case TOK.endOfFile:
                    error("found `%s` instead of array initializer", token.toChars());
                    break;
                }
                break;
            }
            return ia;

        case TOK.void_:
            const tv = peekNext();
            if (tv == TOK.semicolon || tv == TOK.comma)
            {
                nextToken();
                return new AST.VoidInitializer(loc);
            }
            goto Lexpression;

        default:
        Lexpression:
            e = parseAssignExp();
            ie = new AST.ExpInitializer(loc, e);
            return ie;
        }
    }

    /*****************************************
     * Parses default argument initializer expression that is an assign expression,
     * with special handling for __FILE__, __FILE_DIR__, __LINE__, __MODULE__, __FUNCTION__, and __PRETTY_FUNCTION__.
     */
    private AST.Expression parseDefaultInitExp()
    {
        AST.Expression e = null;
        const tv = peekNext();
        if (tv == TOK.comma || tv == TOK.rightParentheses)
        {
            switch (token.value)
            {
            case TOK.file:           e = new AST.FileInitExp(token.loc, TOK.file); break;
            case TOK.fileFullPath:   e = new AST.FileInitExp(token.loc, TOK.fileFullPath); break;
            case TOK.line:           e = new AST.LineInitExp(token.loc); break;
            case TOK.moduleString:   e = new AST.ModuleInitExp(token.loc); break;
            case TOK.functionString: e = new AST.FuncInitExp(token.loc); break;
            case TOK.prettyFunction: e = new AST.PrettyFuncInitExp(token.loc); break;
            default: goto LExp;
            }
            nextToken();
            return e;
        }
        LExp:
        return parseAssignExp();
    }

    private void check(Loc loc, TOK value)
    {
        if (token.value != value)
            error(loc, "found `%s` when expecting `%s`", token.toChars(), Token.toChars(value));
        nextToken();
    }

    void check(TOK value)
    {
        check(token.loc, value);
    }

    private void check(TOK value, const(char)* string)
    {
        if (token.value != value)
            error("found `%s` when expecting `%s` following %s", token.toChars(), Token.toChars(value), string);
        nextToken();
    }

    private void checkParens(TOK value, AST.Expression e)
    {
        if (precedence[e.op] == PREC.rel && !e.parens)
            error(e.loc, "`%s` must be surrounded by parentheses when next to operator `%s`", e.toChars(), Token.toChars(value));
    }

    ///
    private enum NeedDeclaratorId
    {
        no,             // Declarator part must have no identifier
        opt,            // Declarator part identifier is optional
        must,           // Declarator part must have identifier
        mustIfDstyle,   // Declarator part must have identifier, but don't recognize old C-style syntax
    }

    /************************************
     * Determine if the scanner is sitting on the start of a declaration.
     * Params:
     *      t       = current token of the scanner
     *      needId  = flag with additional requirements for a declaration
     *      endtok  = ending token
     *      pt      = will be set ending token (if not null)
     * Output:
     *      true if the token `t` is a declaration, false otherwise
     */
    private bool isDeclaration(Token* t, NeedDeclaratorId needId, TOK endtok, Token** pt)
    {
        //printf("isDeclaration(needId = %d)\n", needId);
        int haveId = 0;
        int haveTpl = 0;

        while (1)
        {
            if ((t.value == TOK.const_ || t.value == TOK.immutable_ || t.value == TOK.inout_ || t.value == TOK.shared_) && peek(t).value != TOK.leftParentheses)
            {
                /* const type
                 * immutable type
                 * shared type
                 * wild type
                 */
                t = peek(t);
                continue;
            }
            break;
        }

        if (!isBasicType(&t))
        {
            goto Lisnot;
        }
        if (!isDeclarator(&t, &haveId, &haveTpl, endtok, needId != NeedDeclaratorId.mustIfDstyle))
            goto Lisnot;
        if ((needId == NeedDeclaratorId.no && !haveId) ||
            (needId == NeedDeclaratorId.opt) ||
            (needId == NeedDeclaratorId.must && haveId) ||
            (needId == NeedDeclaratorId.mustIfDstyle && haveId))
        {
            if (pt)
                *pt = t;
            goto Lis;
        }
        goto Lisnot;

    Lis:
        //printf("\tis declaration, t = %s\n", t.toChars());
        return true;

    Lisnot:
        //printf("\tis not declaration\n");
        return false;
    }

    private bool isBasicType(Token** pt)
    {
        // This code parallels parseBasicType()
        Token* t = *pt;
        switch (t.value)
        {
        case TOK.wchar_:
        case TOK.dchar_:
        case TOK.bool_:
        case TOK.char_:
        case TOK.int8:
        case TOK.uns8:
        case TOK.int16:
        case TOK.uns16:
        case TOK.int32:
        case TOK.uns32:
        case TOK.int64:
        case TOK.uns64:
        case TOK.int128:
        case TOK.uns128:
        case TOK.float32:
        case TOK.float64:
        case TOK.float80:
        case TOK.imaginary32:
        case TOK.imaginary64:
        case TOK.imaginary80:
        case TOK.complex32:
        case TOK.complex64:
        case TOK.complex80:
        case TOK.void_:
            t = peek(t);
            break;

        case TOK.identifier:
        L5:
            t = peek(t);
            if (t.value == TOK.not)
            {
                goto L4;
            }
            goto L3;
            while (1)
            {
            L2:
                t = peek(t);
            L3:
                if (t.value == TOK.dot)
                {
                Ldot:
                    t = peek(t);
                    if (t.value != TOK.identifier)
                        goto Lfalse;
                    t = peek(t);
                    if (t.value != TOK.not)
                        goto L3;
                L4:
                    /* Seen a !
                     * Look for:
                     * !( args ), !identifier, etc.
                     */
                    t = peek(t);
                    switch (t.value)
                    {
                    case TOK.identifier:
                        goto L5;

                    case TOK.leftParentheses:
                        if (!skipParens(t, &t))
                            goto Lfalse;
                        goto L3;

                    case TOK.wchar_:
                    case TOK.dchar_:
                    case TOK.bool_:
                    case TOK.char_:
                    case TOK.int8:
                    case TOK.uns8:
                    case TOK.int16:
                    case TOK.uns16:
                    case TOK.int32:
                    case TOK.uns32:
                    case TOK.int64:
                    case TOK.uns64:
                    case TOK.int128:
                    case TOK.uns128:
                    case TOK.float32:
                    case TOK.float64:
                    case TOK.float80:
                    case TOK.imaginary32:
                    case TOK.imaginary64:
                    case TOK.imaginary80:
                    case TOK.complex32:
                    case TOK.complex64:
                    case TOK.complex80:
                    case TOK.void_:
                    case TOK.int32Literal:
                    case TOK.uns32Literal:
                    case TOK.int64Literal:
                    case TOK.uns64Literal:
                    case TOK.int128Literal:
                    case TOK.uns128Literal:
                    case TOK.float32Literal:
                    case TOK.float64Literal:
                    case TOK.float80Literal:
                    case TOK.imaginary32Literal:
                    case TOK.imaginary64Literal:
                    case TOK.imaginary80Literal:
                    case TOK.null_:
                    case TOK.true_:
                    case TOK.false_:
                    case TOK.charLiteral:
                    case TOK.wcharLiteral:
                    case TOK.dcharLiteral:
                    case TOK.string_:
                    case TOK.hexadecimalString:
                    case TOK.file:
                    case TOK.fileFullPath:
                    case TOK.line:
                    case TOK.moduleString:
                    case TOK.functionString:
                    case TOK.prettyFunction:
                        goto L2;

                    default:
                        goto Lfalse;
                    }
                }
                break;
            }
            break;

        case TOK.dot:
            goto Ldot;

        case TOK.typeof_:
        case TOK.vector:
        case TOK.mixin_:
            /* typeof(exp).identifier...
             */
            t = peek(t);
            if (!skipParens(t, &t))
                goto Lfalse;
            goto L3;

        case TOK.traits:
            // __traits(getMember
            t = peek(t);
            if (t.value != TOK.leftParentheses)
                goto Lfalse;
            auto lp = t;
            t = peek(t);
            if (t.value != TOK.identifier || t.ident != Id.getMember)
                goto Lfalse;
            if (!skipParens(lp, &lp))
                goto Lfalse;
            // we are in a lookup for decl VS statement
            // so we expect a declarator following __trait if it's a type.
            // other usages wont be ambiguous (alias, template instance, type qual, etc.)
            if (lp.value != TOK.identifier)
                goto Lfalse;

            break;

        case TOK.const_:
        case TOK.immutable_:
        case TOK.shared_:
        case TOK.inout_:
            // const(type)  or  immutable(type)  or  shared(type)  or  wild(type)
            t = peek(t);
            if (t.value != TOK.leftParentheses)
                goto Lfalse;
            t = peek(t);
            if (!isDeclaration(t, NeedDeclaratorId.no, TOK.rightParentheses, &t))
            {
                goto Lfalse;
            }
            t = peek(t);
            break;

        default:
            goto Lfalse;
        }
        *pt = t;
        //printf("is\n");
        return true;

    Lfalse:
        //printf("is not\n");
        return false;
    }

    private bool isDeclarator(Token** pt, int* haveId, int* haveTpl, TOK endtok, bool allowAltSyntax = true)
    {
        // This code parallels parseDeclarator()
        Token* t = *pt;
        int parens;

        //printf("Parser::isDeclarator() %s\n", t.toChars());
        if (t.value == TOK.assign)
            return false;

        while (1)
        {
            parens = false;
            switch (t.value)
            {
            case TOK.mul:
            //case TOK.and:
                t = peek(t);
                continue;

            case TOK.leftBracket:
                t = peek(t);
                if (t.value == TOK.rightBracket)
                {
                    t = peek(t);
                }
                else if (isDeclaration(t, NeedDeclaratorId.no, TOK.rightBracket, &t))
                {
                    // It's an associative array declaration
                    t = peek(t);

                    // ...[type].ident
                    if (t.value == TOK.dot && peek(t).value == TOK.identifier)
                    {
                        t = peek(t);
                        t = peek(t);
                    }
                }
                else
                {
                    // [ expression ]
                    // [ expression .. expression ]
                    if (!isExpression(&t))
                        return false;
                    if (t.value == TOK.slice)
                    {
                        t = peek(t);
                        if (!isExpression(&t))
                            return false;
                        if (t.value != TOK.rightBracket)
                            return false;
                        t = peek(t);
                    }
                    else
                    {
                        if (t.value != TOK.rightBracket)
                            return false;
                        t = peek(t);
                        // ...[index].ident
                        if (t.value == TOK.dot && peek(t).value == TOK.identifier)
                        {
                            t = peek(t);
                            t = peek(t);
                        }
                    }
                }
                continue;

            case TOK.identifier:
                if (*haveId)
                    return false;
                *haveId = true;
                t = peek(t);
                break;

            case TOK.leftParentheses:
                if (!allowAltSyntax)
                    return false;   // Do not recognize C-style declarations.

                t = peek(t);
                if (t.value == TOK.rightParentheses)
                    return false; // () is not a declarator

                /* Regard ( identifier ) as not a declarator
                 * BUG: what about ( *identifier ) in
                 *      f(*p)(x);
                 * where f is a class instance with overloaded () ?
                 * Should we just disallow C-style function pointer declarations?
                 */
                if (t.value == TOK.identifier)
                {
                    Token* t2 = peek(t);
                    if (t2.value == TOK.rightParentheses)
                        return false;
                }

                if (!isDeclarator(&t, haveId, null, TOK.rightParentheses))
                    return false;
                t = peek(t);
                parens = true;
                break;

            case TOK.delegate_:
            case TOK.function_:
                t = peek(t);
                if (!isParameters(&t))
                    return false;
                skipAttributes(t, &t);
                continue;

            default:
                break;
            }
            break;
        }

        while (1)
        {
            switch (t.value)
            {
                static if (CARRAYDECL)
                {
                case TOK.leftBracket:
                    parens = false;
                    t = peek(t);
                    if (t.value == TOK.rightBracket)
                    {
                        t = peek(t);
                    }
                    else if (isDeclaration(t, NeedDeclaratorId.no, TOK.rightBracket, &t))
                    {
                        // It's an associative array declaration
                        t = peek(t);
                    }
                    else
                    {
                        // [ expression ]
                        if (!isExpression(&t))
                            return false;
                        if (t.value != TOK.rightBracket)
                            return false;
                        t = peek(t);
                    }
                    continue;
                }

            case TOK.leftParentheses:
                parens = false;
                if (Token* tk = peekPastParen(t))
                {
                    if (tk.value == TOK.leftParentheses)
                    {
                        if (!haveTpl)
                            return false;
                        *haveTpl = 1;
                        t = tk;
                    }
                    else if (tk.value == TOK.assign)
                    {
                        if (!haveTpl)
                            return false;
                        *haveTpl = 1;
                        *pt = tk;
                        return true;
                    }
                }
                if (!isParameters(&t))
                    return false;
                while (1)
                {
                    switch (t.value)
                    {
                    case TOK.const_:
                    case TOK.immutable_:
                    case TOK.shared_:
                    case TOK.inout_:
                    case TOK.pure_:
                    case TOK.nothrow_:
                    case TOK.return_:
                    case TOK.scope_:
                        t = peek(t);
                        continue;

                    case TOK.at:
                        t = peek(t); // skip '@'
                        t = peek(t); // skip identifier
                        continue;

                    default:
                        break;
                    }
                    break;
                }
                continue;

            // Valid tokens that follow a declaration
            case TOK.rightParentheses:
            case TOK.rightBracket:
            case TOK.assign:
            case TOK.comma:
            case TOK.dotDotDot:
            case TOK.semicolon:
            case TOK.leftCurly:
            case TOK.in_:
            case TOK.out_:
            case TOK.do_:
                // The !parens is to disallow unnecessary parentheses
                if (!parens && (endtok == TOK.reserved || endtok == t.value))
                {
                    *pt = t;
                    return true;
                }
                return false;

            case TOK.identifier:
                if (t.ident == Id._body)
                {
                    version (none)
                    {
                        // This deprecation has been disabled for the time being, see PR10763
                        // @@@DEPRECATED@@@
                        // https://github.com/dlang/DIPs/blob/1f5959abe482b1f9094f6484a7d0a3ade77fc2fc/DIPs/accepted/DIP1003.md
                        // Deprecated in 2.091 - Can be removed from 2.101
                        deprecation("Usage of the `body` keyword is deprecated. Use `do` instead.");
                    }
                    goto case TOK.do_;
                }
                goto default;

            case TOK.if_:
                return haveTpl ? true : false;

            // Used for mixin type parsing
            case TOK.endOfFile:
                if (endtok == TOK.endOfFile)
                    goto case TOK.do_;
                return false;

            default:
                return false;
            }
        }
        assert(0);
    }

    private bool isParameters(Token** pt)
    {
        // This code parallels parseParameters()
        Token* t = *pt;

        //printf("isParameters()\n");
        if (t.value != TOK.leftParentheses)
            return false;

        t = peek(t);
        for (; 1; t = peek(t))
        {
        L1:
            switch (t.value)
            {
            case TOK.rightParentheses:
                break;

            case TOK.dotDotDot:
                t = peek(t);
                break;

            case TOK.in_:
            case TOK.out_:
            case TOK.ref_:
            case TOK.lazy_:
            case TOK.scope_:
            case TOK.final_:
            case TOK.auto_:
            case TOK.return_:
                continue;

            case TOK.const_:
            case TOK.immutable_:
            case TOK.shared_:
            case TOK.inout_:
                t = peek(t);
                if (t.value == TOK.leftParentheses)
                {
                    t = peek(t);
                    if (!isDeclaration(t, NeedDeclaratorId.no, TOK.rightParentheses, &t))
                        return false;
                    t = peek(t); // skip past closing ')'
                    goto L2;
                }
                goto L1;

                version (none)
                {
                case TOK.static_:
                    continue;
                case TOK.auto_:
                case TOK.alias_:
                    t = peek(t);
                    if (t.value == TOK.identifier)
                        t = peek(t);
                    if (t.value == TOK.assign)
                    {
                        t = peek(t);
                        if (!isExpression(&t))
                            return false;
                    }
                    goto L3;
                }

            default:
                {
                    if (!isBasicType(&t))
                        return false;
                L2:
                    int tmp = false;
                    if (t.value != TOK.dotDotDot && !isDeclarator(&t, &tmp, null, TOK.reserved))
                        return false;
                    if (t.value == TOK.assign)
                    {
                        t = peek(t);
                        if (!isExpression(&t))
                            return false;
                    }
                    if (t.value == TOK.dotDotDot)
                    {
                        t = peek(t);
                        break;
                    }
                }
                if (t.value == TOK.comma)
                {
                    continue;
                }
                break;
            }
            break;
        }
        if (t.value != TOK.rightParentheses)
            return false;
        t = peek(t);
        *pt = t;
        return true;
    }

    private bool isExpression(Token** pt)
    {
        // This is supposed to determine if something is an expression.
        // What it actually does is scan until a closing right bracket
        // is found.

        Token* t = *pt;
        int brnest = 0;
        int panest = 0;
        int curlynest = 0;

        for (;; t = peek(t))
        {
            switch (t.value)
            {
            case TOK.leftBracket:
                brnest++;
                continue;

            case TOK.rightBracket:
                if (--brnest >= 0)
                    continue;
                break;

            case TOK.leftParentheses:
                panest++;
                continue;

            case TOK.comma:
                if (brnest || panest)
                    continue;
                break;

            case TOK.rightParentheses:
                if (--panest >= 0)
                    continue;
                break;

            case TOK.leftCurly:
                curlynest++;
                continue;

            case TOK.rightCurly:
                if (--curlynest >= 0)
                    continue;
                return false;

            case TOK.slice:
                if (brnest)
                    continue;
                break;

            case TOK.semicolon:
                if (curlynest)
                    continue;
                return false;

            case TOK.endOfFile:
                return false;

            default:
                continue;
            }
            break;
        }

        *pt = t;
        return true;
    }

    /*******************************************
     * Skip parens, brackets.
     * Input:
     *      t is on opening $(LPAREN)
     * Output:
     *      *pt is set to closing token, which is '$(RPAREN)' on success
     * Returns:
     *      true    successful
     *      false   some parsing error
     */
    private bool skipParens(Token* t, Token** pt)
    {
        if (t.value != TOK.leftParentheses)
            return false;

        int parens = 0;

        while (1)
        {
            switch (t.value)
            {
            case TOK.leftParentheses:
                parens++;
                break;

            case TOK.rightParentheses:
                parens--;
                if (parens < 0)
                    goto Lfalse;
                if (parens == 0)
                    goto Ldone;
                break;

            case TOK.endOfFile:
                goto Lfalse;

            default:
                break;
            }
            t = peek(t);
        }
    Ldone:
        if (pt)
            *pt = peek(t); // skip found rparen
        return true;

    Lfalse:
        return false;
    }

    private bool skipParensIf(Token* t, Token** pt)
    {
        if (t.value != TOK.leftParentheses)
        {
            if (pt)
                *pt = t;
            return true;
        }
        return skipParens(t, pt);
    }

    //returns true if the next value (after optional matching parens) is expected
    private bool hasOptionalParensThen(Token* t, TOK expected)
    {
        Token* tk;
        if (!skipParensIf(t, &tk))
            return false;
        return tk.value == expected;
    }

    /*******************************************
     * Skip attributes.
     * Input:
     *      t is on a candidate attribute
     * Output:
     *      *pt is set to first non-attribute token on success
     * Returns:
     *      true    successful
     *      false   some parsing error
     */
    private bool skipAttributes(Token* t, Token** pt)
    {
        while (1)
        {
            switch (t.value)
            {
            case TOK.const_:
            case TOK.immutable_:
            case TOK.shared_:
            case TOK.inout_:
            case TOK.final_:
            case TOK.auto_:
            case TOK.scope_:
            case TOK.override_:
            case TOK.abstract_:
            case TOK.synchronized_:
                break;

            case TOK.deprecated_:
                if (peek(t).value == TOK.leftParentheses)
                {
                    t = peek(t);
                    if (!skipParens(t, &t))
                        goto Lerror;
                    // t is on the next of closing parenthesis
                    continue;
                }
                break;

            case TOK.nothrow_:
            case TOK.pure_:
            case TOK.ref_:
            case TOK.gshared:
            case TOK.return_:
                break;

            case TOK.at:
                t = peek(t);
                if (t.value == TOK.identifier)
                {
                    /* @identifier
                     * @identifier!arg
                     * @identifier!(arglist)
                     * any of the above followed by (arglist)
                     * @predefined_attribute
                     */
                    if (isBuiltinAtAttribute(t.ident))
                        break;
                    t = peek(t);
                    if (t.value == TOK.not)
                    {
                        t = peek(t);
                        if (t.value == TOK.leftParentheses)
                        {
                            // @identifier!(arglist)
                            if (!skipParens(t, &t))
                                goto Lerror;
                            // t is on the next of closing parenthesis
                        }
                        else
                        {
                            // @identifier!arg
                            // Do low rent skipTemplateArgument
                            if (t.value == TOK.vector)
                            {
                                // identifier!__vector(type)
                                t = peek(t);
                                if (!skipParens(t, &t))
                                    goto Lerror;
                            }
                            else
                                t = peek(t);
                        }
                    }
                    if (t.value == TOK.leftParentheses)
                    {
                        if (!skipParens(t, &t))
                            goto Lerror;
                        // t is on the next of closing parenthesis
                        continue;
                    }
                    continue;
                }
                if (t.value == TOK.leftParentheses)
                {
                    // @( ArgumentList )
                    if (!skipParens(t, &t))
                        goto Lerror;
                    // t is on the next of closing parenthesis
                    continue;
                }
                goto Lerror;

            default:
                goto Ldone;
            }
            t = peek(t);
        }
    Ldone:
        if (pt)
            *pt = t;
        return true;

    Lerror:
        return false;
    }

    AST.Expression parseExpression()
    {
        auto loc = token.loc;

        //printf("Parser::parseExpression() loc = %d\n", loc.linnum);
        auto e = parseAssignExp();
        while (token.value == TOK.comma)
        {
            nextToken();
            auto e2 = parseAssignExp();
            e = new AST.CommaExp(loc, e, e2, false);
            loc = token.loc;
        }
        return e;
    }

    /********************************* Expression Parser ***************************/

    AST.Expression parsePrimaryExp()
    {
        AST.Expression e;
        AST.Type t;
        Identifier id;
        const loc = token.loc;

        //printf("parsePrimaryExp(): loc = %d\n", loc.linnum);
        switch (token.value)
        {
        case TOK.identifier:
            {
                if (peekNext() == TOK.min && peekNext2() == TOK.greaterThan)
                {
                    // skip ident.
                    nextToken();
                    nextToken();
                    nextToken();
                    error("use `.` for member lookup, not `->`");
                    goto Lerr;
                }

                if (peekNext() == TOK.goesTo)
                    goto case_delegate;

                id = token.ident;
                nextToken();
                TOK save;
                if (token.value == TOK.not && (save = peekNext()) != TOK.is_ && save != TOK.in_)
                {
                    // identifier!(template-argument-list)
                    auto tempinst = new AST.TemplateInstance(loc, id, parseTemplateArguments());
                    e = new AST.ScopeExp(loc, tempinst);
                }
                else
                    e = new AST.IdentifierExp(loc, id);
                break;
            }
        case TOK.dollar:
            if (!inBrackets)
                error("`$` is valid only inside [] of index or slice");
            e = new AST.DollarExp(loc);
            nextToken();
            break;

        case TOK.dot:
            // Signal global scope '.' operator with "" identifier
            e = new AST.IdentifierExp(loc, Id.empty);
            break;

        case TOK.this_:
            e = new AST.ThisExp(loc);
            nextToken();
            break;

        case TOK.super_:
            e = new AST.SuperExp(loc);
            nextToken();
            break;

        case TOK.int32Literal:
            e = new AST.IntegerExp(loc, cast(d_int32)token.intvalue, AST.Type.tint32);
            nextToken();
            break;

        case TOK.uns32Literal:
            e = new AST.IntegerExp(loc, cast(d_uns32)token.unsvalue, AST.Type.tuns32);
            nextToken();
            break;

        case TOK.int64Literal:
            e = new AST.IntegerExp(loc, token.intvalue, AST.Type.tint64);
            nextToken();
            break;

        case TOK.uns64Literal:
            e = new AST.IntegerExp(loc, token.unsvalue, AST.Type.tuns64);
            nextToken();
            break;

        case TOK.float32Literal:
            e = new AST.RealExp(loc, token.floatvalue, AST.Type.tfloat32);
            nextToken();
            break;

        case TOK.float64Literal:
            e = new AST.RealExp(loc, token.floatvalue, AST.Type.tfloat64);
            nextToken();
            break;

        case TOK.float80Literal:
            e = new AST.RealExp(loc, token.floatvalue, AST.Type.tfloat80);
            nextToken();
            break;

        case TOK.imaginary32Literal:
            e = new AST.RealExp(loc, token.floatvalue, AST.Type.timaginary32);
            nextToken();
            break;

        case TOK.imaginary64Literal:
            e = new AST.RealExp(loc, token.floatvalue, AST.Type.timaginary64);
            nextToken();
            break;

        case TOK.imaginary80Literal:
            e = new AST.RealExp(loc, token.floatvalue, AST.Type.timaginary80);
            nextToken();
            break;

        case TOK.null_:
            e = new AST.NullExp(loc);
            nextToken();
            break;

        case TOK.file:
            {
                const(char)* s = loc.filename ? loc.filename : mod.ident.toChars();
                e = new AST.StringExp(loc, s.toDString());
                nextToken();
                break;
            }
        case TOK.fileFullPath:
            {
                assert(loc.isValid(), "__FILE_FULL_PATH__ does not work with an invalid location");
                const s = FileName.toAbsolute(loc.filename);
                e = new AST.StringExp(loc, s.toDString());
                nextToken();
                break;
            }

        case TOK.line:
            e = new AST.IntegerExp(loc, loc.linnum, AST.Type.tint32);
            nextToken();
            break;

        case TOK.moduleString:
            {
                const(char)* s = md ? md.toChars() : mod.toChars();
                e = new AST.StringExp(loc, s.toDString());
                nextToken();
                break;
            }
        case TOK.functionString:
            e = new AST.FuncInitExp(loc);
            nextToken();
            break;

        case TOK.prettyFunction:
            e = new AST.PrettyFuncInitExp(loc);
            nextToken();
            break;

        case TOK.true_:
            e = new AST.IntegerExp(loc, 1, AST.Type.tbool);
            nextToken();
            break;

        case TOK.false_:
            e = new AST.IntegerExp(loc, 0, AST.Type.tbool);
            nextToken();
            break;

        case TOK.charLiteral:
            e = new AST.IntegerExp(loc, cast(d_uns8)token.unsvalue, AST.Type.tchar);
            nextToken();
            break;

        case TOK.wcharLiteral:
            e = new AST.IntegerExp(loc, cast(d_uns16)token.unsvalue, AST.Type.twchar);
            nextToken();
            break;

        case TOK.dcharLiteral:
            e = new AST.IntegerExp(loc, cast(d_uns32)token.unsvalue, AST.Type.tdchar);
            nextToken();
            break;

        case TOK.string_:
        case TOK.hexadecimalString:
            {
                // cat adjacent strings
                auto s = token.ustring;
                auto len = token.len;
                auto postfix = token.postfix;
                while (1)
                {
                    const prev = token;
                    nextToken();
                    if (token.value == TOK.string_ || token.value == TOK.hexadecimalString)
                    {
                        if (token.postfix)
                        {
                            if (token.postfix != postfix)
                                error("mismatched string literal postfixes `'%c'` and `'%c'`", postfix, token.postfix);
                            postfix = token.postfix;
                        }

                        error("Implicit string concatenation is deprecated, use %s ~ %s instead",
                                    prev.toChars(), token.toChars());

                        const len1 = len;
                        const len2 = token.len;
                        len = len1 + len2;
                        auto s2 = cast(char*)mem.xmalloc_noscan(len * char.sizeof);
                        memcpy(s2, s, len1 * char.sizeof);
                        memcpy(s2 + len1, token.ustring, len2 * char.sizeof);
                        s = s2;
                    }
                    else
                        break;
                }
                e = new AST.StringExp(loc, s[0 .. len], len, 1, postfix);
                break;
            }
        case TOK.void_:
            t = AST.Type.tvoid;
            goto LabelX;

        case TOK.int8:
            t = AST.Type.tint8;
            goto LabelX;

        case TOK.uns8:
            t = AST.Type.tuns8;
            goto LabelX;

        case TOK.int16:
            t = AST.Type.tint16;
            goto LabelX;

        case TOK.uns16:
            t = AST.Type.tuns16;
            goto LabelX;

        case TOK.int32:
            t = AST.Type.tint32;
            goto LabelX;

        case TOK.uns32:
            t = AST.Type.tuns32;
            goto LabelX;

        case TOK.int64:
            t = AST.Type.tint64;
            goto LabelX;

        case TOK.uns64:
            t = AST.Type.tuns64;
            goto LabelX;

        case TOK.int128:
            t = AST.Type.tint128;
            goto LabelX;

        case TOK.uns128:
            t = AST.Type.tuns128;
            goto LabelX;

        case TOK.float32:
            t = AST.Type.tfloat32;
            goto LabelX;

        case TOK.float64:
            t = AST.Type.tfloat64;
            goto LabelX;

        case TOK.float80:
            t = AST.Type.tfloat80;
            goto LabelX;

        case TOK.imaginary32:
            t = AST.Type.timaginary32;
            goto LabelX;

        case TOK.imaginary64:
            t = AST.Type.timaginary64;
            goto LabelX;

        case TOK.imaginary80:
            t = AST.Type.timaginary80;
            goto LabelX;

        case TOK.complex32:
            t = AST.Type.tcomplex32;
            goto LabelX;

        case TOK.complex64:
            t = AST.Type.tcomplex64;
            goto LabelX;

        case TOK.complex80:
            t = AST.Type.tcomplex80;
            goto LabelX;

        case TOK.bool_:
            t = AST.Type.tbool;
            goto LabelX;

        case TOK.char_:
            t = AST.Type.tchar;
            goto LabelX;

        case TOK.wchar_:
            t = AST.Type.twchar;
            goto LabelX;

        case TOK.dchar_:
            t = AST.Type.tdchar;
            goto LabelX;
        LabelX:
            nextToken();
            if (token.value == TOK.leftParentheses)
            {
                e = new AST.TypeExp(loc, t);
                e = new AST.CallExp(loc, e, parseArguments());
                break;
            }
            check(TOK.dot, t.toChars());
            if (token.value != TOK.identifier)
            {
                error("found `%s` when expecting identifier following `%s`.", token.toChars(), t.toChars());
                goto Lerr;
            }
            e = new AST.DotIdExp(loc, new AST.TypeExp(loc, t), token.ident);
            nextToken();
            break;

        case TOK.typeof_:
            {
                t = parseTypeof();
                e = new AST.TypeExp(loc, t);
                break;
            }
        case TOK.vector:
            {
                t = parseVector();
                e = new AST.TypeExp(loc, t);
                break;
            }
        case TOK.typeid_:
            {
                nextToken();
                check(TOK.leftParentheses, "`typeid`");
                RootObject o = parseTypeOrAssignExp();
                check(TOK.rightParentheses);
                e = new AST.TypeidExp(loc, o);
                break;
            }
        case TOK.traits:
            {
                /* __traits(identifier, args...)
                 */
                Identifier ident;
                AST.Objects* args = null;

                nextToken();
                check(TOK.leftParentheses);
                if (token.value != TOK.identifier)
                {
                    error("`__traits(identifier, args...)` expected");
                    goto Lerr;
                }
                ident = token.ident;
                nextToken();
                if (token.value == TOK.comma)
                    args = parseTemplateArgumentList(); // __traits(identifier, args...)
                else
                    check(TOK.rightParentheses); // __traits(identifier)

                e = new AST.TraitsExp(loc, ident, args);
                break;
            }
        case TOK.is_:
            {
                AST.Type targ;
                Identifier ident = null;
                AST.Type tspec = null;
                TOK tok = TOK.reserved;
                TOK tok2 = TOK.reserved;
                AST.TemplateParameters* tpl = null;

                nextToken();
                if (token.value == TOK.leftParentheses)
                {
                    nextToken();
                    if (token.value == TOK.identifier && peekNext() == TOK.leftParentheses)
                    {
                        error(loc, "unexpected `(` after `%s`, inside `is` expression. Try enclosing the contents of `is` with a `typeof` expression", token.toChars());
                        nextToken();
                        Token* tempTok = peekPastParen(&token);
                        memcpy(&token, tempTok, Token.sizeof);
                        goto Lerr;
                    }
                    targ = parseType(&ident);
                    if (token.value == TOK.colon || token.value == TOK.equal)
                    {
                        tok = token.value;
                        nextToken();
                        if (tok == TOK.equal && (token.value == TOK.struct_ || token.value == TOK.union_
                            || token.value == TOK.class_ || token.value == TOK.super_ || token.value == TOK.enum_
                            || token.value == TOK.interface_ || token.value == TOK.package_ || token.value == TOK.module_
                            || token.value == TOK.argumentTypes || token.value == TOK.parameters
                            || token.value == TOK.const_ && peekNext() == TOK.rightParentheses
                            || token.value == TOK.immutable_ && peekNext() == TOK.rightParentheses
                            || token.value == TOK.shared_ && peekNext() == TOK.rightParentheses
                            || token.value == TOK.inout_ && peekNext() == TOK.rightParentheses || token.value == TOK.function_
                            || token.value == TOK.delegate_ || token.value == TOK.return_
                            || (token.value == TOK.vector && peekNext() == TOK.rightParentheses)))
                        {
                            tok2 = token.value;
                            nextToken();
                        }
                        else
                        {
                            tspec = parseType();
                        }
                    }
                    if (tspec)
                    {
                        if (token.value == TOK.comma)
                            tpl = parseTemplateParameterList(1);
                        else
                        {
                            tpl = new AST.TemplateParameters();
                            check(TOK.rightParentheses);
                        }
                    }
                    else
                        check(TOK.rightParentheses);
                }
                else
                {
                    error("`type identifier : specialization` expected following `is`");
                    goto Lerr;
                }
                e = new AST.IsExp(loc, targ, ident, tok, tspec, tok2, tpl);
                break;
            }
        case TOK.assert_:
            {
                // https://dlang.org/spec/expression.html#assert_expressions
                AST.Expression msg = null;

                nextToken();
                check(TOK.leftParentheses, "`assert`");
                e = parseAssignExp();
                if (token.value == TOK.comma)
                {
                    nextToken();
                    if (token.value != TOK.rightParentheses)
                    {
                        msg = parseAssignExp();
                        if (token.value == TOK.comma)
                            nextToken();
                    }
                }
                check(TOK.rightParentheses);
                e = new AST.AssertExp(loc, e, msg);
                break;
            }
        case TOK.mixin_:
            {
                // https://dlang.org/spec/expression.html#mixin_expressions
                nextToken();
                if (token.value != TOK.leftParentheses)
                    error("found `%s` when expecting `%s` following %s", token.toChars(), Token.toChars(TOK.leftParentheses), "`mixin`".ptr);
                auto exps = parseArguments();
                e = new AST.CompileExp(loc, exps);
                break;
            }
        case TOK.import_:
            {
                nextToken();
                check(TOK.leftParentheses, "`import`");
                e = parseAssignExp();
                check(TOK.rightParentheses);
                e = new AST.ImportExp(loc, e);
                break;
            }
        case TOK.new_:
            e = parseNewExp(null);
            break;

        case TOK.ref_:
            {
                if (peekNext() == TOK.leftParentheses)
                {
                    Token* tk = peekPastParen(peek(&token));
                    if (skipAttributes(tk, &tk) && (tk.value == TOK.goesTo || tk.value == TOK.leftCurly))
                    {
                        // ref (arguments) => expression
                        // ref (arguments) { statements... }
                        goto case_delegate;
                    }
                }
                nextToken();
                error("found `%s` when expecting function literal following `ref`", token.toChars());
                goto Lerr;
            }
        case TOK.leftParentheses:
            {
                Token* tk = peekPastParen(&token);
                if (skipAttributes(tk, &tk) && (tk.value == TOK.goesTo || tk.value == TOK.leftCurly))
                {
                    // (arguments) => expression
                    // (arguments) { statements... }
                    goto case_delegate;
                }

                // ( expression )
                nextToken();
                e = parseExpression();
                e.parens = 1;
                check(loc, TOK.rightParentheses);
                break;
            }
        case TOK.leftBracket:
            {
                /* Parse array literals and associative array literals:
                 *  [ value, value, value ... ]
                 *  [ key:value, key:value, key:value ... ]
                 */
                auto values = new AST.Expressions();
                AST.Expressions* keys = null;

                nextToken();
                while (token.value != TOK.rightBracket && token.value != TOK.endOfFile)
                {
                    e = parseAssignExp();
                    if (token.value == TOK.colon && (keys || values.dim == 0))
                    {
                        nextToken();
                        if (!keys)
                            keys = new AST.Expressions();
                        keys.push(e);
                        e = parseAssignExp();
                    }
                    else if (keys)
                    {
                        error("`key:value` expected for associative array literal");
                        keys = null;
                    }
                    values.push(e);
                    if (token.value == TOK.rightBracket)
                        break;
                    check(TOK.comma);
                }
                check(loc, TOK.rightBracket);

                if (keys)
                    e = new AST.AssocArrayLiteralExp(loc, keys, values);
                else
                    e = new AST.ArrayLiteralExp(loc, null, values);
                break;
            }
        case TOK.leftCurly:
        case TOK.function_:
        case TOK.delegate_:
        case_delegate:
            {
                AST.Dsymbol s = parseFunctionLiteral();
                e = new AST.FuncExp(loc, s);
                break;
            }
        default:
            error("expression expected, not `%s`", token.toChars());
        Lerr:
            // Anything for e, as long as it's not NULL
            e = new AST.IntegerExp(loc, 0, AST.Type.tint32);
            nextToken();
            break;
        }
        return e;
    }

    private AST.Expression parseUnaryExp()
    {
        AST.Expression e;
        const loc = token.loc;

        switch (token.value)
        {
        case TOK.and:
            nextToken();
            e = parseUnaryExp();
            e = new AST.AddrExp(loc, e);
            break;

        case TOK.plusPlus:
            nextToken();
            e = parseUnaryExp();
            //e = new AddAssignExp(loc, e, new IntegerExp(loc, 1, Type::tint32));
            e = new AST.PreExp(TOK.prePlusPlus, loc, e);
            break;

        case TOK.minusMinus:
            nextToken();
            e = parseUnaryExp();
            //e = new MinAssignExp(loc, e, new IntegerExp(loc, 1, Type::tint32));
            e = new AST.PreExp(TOK.preMinusMinus, loc, e);
            break;

        case TOK.mul:
            nextToken();
            e = parseUnaryExp();
            e = new AST.PtrExp(loc, e);
            break;

        case TOK.min:
            nextToken();
            e = parseUnaryExp();
            e = new AST.NegExp(loc, e);
            break;

        case TOK.add:
            nextToken();
            e = parseUnaryExp();
            e = new AST.UAddExp(loc, e);
            break;

        case TOK.not:
            nextToken();
            e = parseUnaryExp();
            e = new AST.NotExp(loc, e);
            break;

        case TOK.tilde:
            nextToken();
            e = parseUnaryExp();
            e = new AST.ComExp(loc, e);
            break;

        case TOK.delete_:
            nextToken();
            e = parseUnaryExp();
            e = new AST.DeleteExp(loc, e, false);
            break;

        case TOK.cast_: // cast(type) expression
            {
                nextToken();
                check(TOK.leftParentheses);
                /* Look for cast(), cast(const), cast(immutable),
                 * cast(shared), cast(shared const), cast(wild), cast(shared wild)
                 */
                ubyte m = 0;
                while (1)
                {
                    switch (token.value)
                    {
                    case TOK.const_:
                        if (peekNext() == TOK.leftParentheses)
                            break; // const as type constructor
                        m |= AST.MODFlags.const_; // const as storage class
                        nextToken();
                        continue;

                    case TOK.immutable_:
                        if (peekNext() == TOK.leftParentheses)
                            break;
                        m |= AST.MODFlags.immutable_;
                        nextToken();
                        continue;

                    case TOK.shared_:
                        if (peekNext() == TOK.leftParentheses)
                            break;
                        m |= AST.MODFlags.shared_;
                        nextToken();
                        continue;

                    case TOK.inout_:
                        if (peekNext() == TOK.leftParentheses)
                            break;
                        m |= AST.MODFlags.wild;
                        nextToken();
                        continue;

                    default:
                        break;
                    }
                    break;
                }
                if (token.value == TOK.rightParentheses)
                {
                    nextToken();
                    e = parseUnaryExp();
                    e = new AST.CastExp(loc, e, m);
                }
                else
                {
                    AST.Type t = parseType(); // cast( type )
                    t = t.addMod(m); // cast( const type )
                    check(TOK.rightParentheses);
                    e = parseUnaryExp();
                    e = new AST.CastExp(loc, e, t);
                }
                break;
            }
        case TOK.inout_:
        case TOK.shared_:
        case TOK.const_:
        case TOK.immutable_: // immutable(type)(arguments) / immutable(type).init
            {
                StorageClass stc = parseTypeCtor();

                AST.Type t = parseBasicType();
                t = t.addSTC(stc);

                if (stc == 0 && token.value == TOK.dot)
                {
                    nextToken();
                    if (token.value != TOK.identifier)
                    {
                        error("identifier expected following `(type)`.");
                        return null;
                    }
                    e = new AST.DotIdExp(loc, new AST.TypeExp(loc, t), token.ident);
                    nextToken();
                    e = parsePostExp(e);
                }
                else
                {
                    e = new AST.TypeExp(loc, t);
                    if (token.value != TOK.leftParentheses)
                    {
                        error("`(arguments)` expected following `%s`", t.toChars());
                        return e;
                    }
                    e = new AST.CallExp(loc, e, parseArguments());
                }
                break;
            }
        case TOK.leftParentheses:
            {
                auto tk = peek(&token);
                static if (CCASTSYNTAX)
                {
                    // If cast
                    if (isDeclaration(tk, NeedDeclaratorId.no, TOK.rightParentheses, &tk))
                    {
                        tk = peek(tk); // skip over right parenthesis
                        switch (tk.value)
                        {
                        case TOK.not:
                            tk = peek(tk);
                            if (tk.value == TOK.is_ || tk.value == TOK.in_) // !is or !in
                                break;
                            goto case;

                        case TOK.dot:
                        case TOK.plusPlus:
                        case TOK.minusMinus:
                        case TOK.delete_:
                        case TOK.new_:
                        case TOK.leftParentheses:
                        case TOK.identifier:
                        case TOK.this_:
                        case TOK.super_:
                        case TOK.int32Literal:
                        case TOK.uns32Literal:
                        case TOK.int64Literal:
                        case TOK.uns64Literal:
                        case TOK.int128Literal:
                        case TOK.uns128Literal:
                        case TOK.float32Literal:
                        case TOK.float64Literal:
                        case TOK.float80Literal:
                        case TOK.imaginary32Literal:
                        case TOK.imaginary64Literal:
                        case TOK.imaginary80Literal:
                        case TOK.null_:
                        case TOK.true_:
                        case TOK.false_:
                        case TOK.charLiteral:
                        case TOK.wcharLiteral:
                        case TOK.dcharLiteral:
                        case TOK.string_:
                            version (none)
                            {
                            case TOK.tilde:
                            case TOK.and:
                            case TOK.mul:
                            case TOK.min:
                            case TOK.add:
                            }
                        case TOK.function_:
                        case TOK.delegate_:
                        case TOK.typeof_:
                        case TOK.traits:
                        case TOK.vector:
                        case TOK.file:
                        case TOK.fileFullPath:
                        case TOK.line:
                        case TOK.moduleString:
                        case TOK.functionString:
                        case TOK.prettyFunction:
                        case TOK.wchar_:
                        case TOK.dchar_:
                        case TOK.bool_:
                        case TOK.char_:
                        case TOK.int8:
                        case TOK.uns8:
                        case TOK.int16:
                        case TOK.uns16:
                        case TOK.int32:
                        case TOK.uns32:
                        case TOK.int64:
                        case TOK.uns64:
                        case TOK.int128:
                        case TOK.uns128:
                        case TOK.float32:
                        case TOK.float64:
                        case TOK.float80:
                        case TOK.imaginary32:
                        case TOK.imaginary64:
                        case TOK.imaginary80:
                        case TOK.complex32:
                        case TOK.complex64:
                        case TOK.complex80:
                        case TOK.void_:
                            {
                                // (type) una_exp
                                nextToken();
                                auto t = parseType();
                                check(TOK.rightParentheses);

                                // if .identifier
                                // or .identifier!( ... )
                                if (token.value == TOK.dot)
                                {
                                    if (peekNext() != TOK.identifier && peekNext() != TOK.new_)
                                    {
                                        error("identifier or new keyword expected following `(...)`.");
                                        return null;
                                    }
                                    e = new AST.TypeExp(loc, t);
                                    e.parens = true;
                                    e = parsePostExp(e);
                                }
                                else
                                {
                                    e = parseUnaryExp();
                                    e = new AST.CastExp(loc, e, t);
                                    error("C style cast illegal, use `%s`", e.toChars());
                                }
                                return e;
                            }
                        default:
                            break;
                        }
                    }
                }
                e = parsePrimaryExp();
                e = parsePostExp(e);
                break;
            }
        default:
            e = parsePrimaryExp();
            e = parsePostExp(e);
            break;
        }
        assert(e);

        // ^^ is right associative and has higher precedence than the unary operators
        while (token.value == TOK.pow)
        {
            nextToken();
            AST.Expression e2 = parseUnaryExp();
            e = new AST.PowExp(loc, e, e2);
        }

        return e;
    }

    private AST.Expression parsePostExp(AST.Expression e)
    {
        while (1)
        {
            const loc = token.loc;
            switch (token.value)
            {
            case TOK.dot:
                nextToken();
                if (token.value == TOK.identifier)
                {
                    Identifier id = token.ident;

                    nextToken();
                    if (token.value == TOK.not && peekNext() != TOK.is_ && peekNext() != TOK.in_)
                    {
                        AST.Objects* tiargs = parseTemplateArguments();
                        e = new AST.DotTemplateInstanceExp(loc, e, id, tiargs);
                    }
                    else
                        e = new AST.DotIdExp(loc, e, id);
                    continue;
                }
                if (token.value == TOK.new_)
                {
                    e = parseNewExp(e);
                    continue;
                }
                error("identifier or `new` expected following `.`, not `%s`", token.toChars());
                break;

            case TOK.plusPlus:
                e = new AST.PostExp(TOK.plusPlus, loc, e);
                break;

            case TOK.minusMinus:
                e = new AST.PostExp(TOK.minusMinus, loc, e);
                break;

            case TOK.leftParentheses:
                e = new AST.CallExp(loc, e, parseArguments());
                continue;

            case TOK.leftBracket:
                {
                    // array dereferences:
                    //      array[index]
                    //      array[]
                    //      array[lwr .. upr]
                    AST.Expression index;
                    AST.Expression upr;
                    auto arguments = new AST.Expressions();

                    inBrackets++;
                    nextToken();
                    while (token.value != TOK.rightBracket && token.value != TOK.endOfFile)
                    {
                        index = parseAssignExp();
                        if (token.value == TOK.slice)
                        {
                            // array[..., lwr..upr, ...]
                            nextToken();
                            upr = parseAssignExp();
                            arguments.push(new AST.IntervalExp(loc, index, upr));
                        }
                        else
                            arguments.push(index);
                        if (token.value == TOK.rightBracket)
                            break;
                        check(TOK.comma);
                    }
                    check(TOK.rightBracket);
                    inBrackets--;
                    e = new AST.ArrayExp(loc, e, arguments);
                    continue;
                }
            default:
                return e;
            }
            nextToken();
        }
    }

    private AST.Expression parseMulExp()
    {
        const loc = token.loc;
        auto e = parseUnaryExp();

        while (1)
        {
            switch (token.value)
            {
            case TOK.mul:
                nextToken();
                auto e2 = parseUnaryExp();
                e = new AST.MulExp(loc, e, e2);
                continue;

            case TOK.div:
                nextToken();
                auto e2 = parseUnaryExp();
                e = new AST.DivExp(loc, e, e2);
                continue;

            case TOK.mod:
                nextToken();
                auto e2 = parseUnaryExp();
                e = new AST.ModExp(loc, e, e2);
                continue;

            default:
                break;
            }
            break;
        }
        return e;
    }

    private AST.Expression parseAddExp()
    {
        const loc = token.loc;
        auto e = parseMulExp();

        while (1)
        {
            switch (token.value)
            {
            case TOK.add:
                nextToken();
                auto e2 = parseMulExp();
                e = new AST.AddExp(loc, e, e2);
                continue;

            case TOK.min:
                nextToken();
                auto e2 = parseMulExp();
                e = new AST.MinExp(loc, e, e2);
                continue;

            case TOK.tilde:
                nextToken();
                auto e2 = parseMulExp();
                e = new AST.CatExp(loc, e, e2);
                continue;

            default:
                break;
            }
            break;
        }
        return e;
    }

    private AST.Expression parseShiftExp()
    {
        const loc = token.loc;
        auto e = parseAddExp();

        while (1)
        {
            switch (token.value)
            {
            case TOK.leftShift:
                nextToken();
                auto e2 = parseAddExp();
                e = new AST.ShlExp(loc, e, e2);
                continue;

            case TOK.rightShift:
                nextToken();
                auto e2 = parseAddExp();
                e = new AST.ShrExp(loc, e, e2);
                continue;

            case TOK.unsignedRightShift:
                nextToken();
                auto e2 = parseAddExp();
                e = new AST.UshrExp(loc, e, e2);
                continue;

            default:
                break;
            }
            break;
        }
        return e;
    }

    private AST.Expression parseCmpExp()
    {
        const loc = token.loc;

        auto e = parseShiftExp();
        TOK op = token.value;

        switch (op)
        {
        case TOK.equal:
        case TOK.notEqual:
            nextToken();
            auto e2 = parseShiftExp();
            e = new AST.EqualExp(op, loc, e, e2);
            break;

        case TOK.is_:
            op = TOK.identity;
            goto L1;

        case TOK.not:
        {
            // Attempt to identify '!is'
            const tv = peekNext();
            if (tv == TOK.in_)
            {
                nextToken();
                nextToken();
                auto e2 = parseShiftExp();
                e = new AST.InExp(loc, e, e2);
                e = new AST.NotExp(loc, e);
                break;
            }
            if (tv != TOK.is_)
                break;
            nextToken();
            op = TOK.notIdentity;
            goto L1;
        }
        L1:
            nextToken();
            auto e2 = parseShiftExp();
            e = new AST.IdentityExp(op, loc, e, e2);
            break;

        case TOK.lessThan:
        case TOK.lessOrEqual:
        case TOK.greaterThan:
        case TOK.greaterOrEqual:
            nextToken();
            auto e2 = parseShiftExp();
            e = new AST.CmpExp(op, loc, e, e2);
            break;

        case TOK.in_:
            nextToken();
            auto e2 = parseShiftExp();
            e = new AST.InExp(loc, e, e2);
            break;

        default:
            break;
        }
        return e;
    }

    private AST.Expression parseAndExp()
    {
        Loc loc = token.loc;
        auto e = parseCmpExp();
        while (token.value == TOK.and)
        {
            checkParens(TOK.and, e);
            nextToken();
            auto e2 = parseCmpExp();
            checkParens(TOK.and, e2);
            e = new AST.AndExp(loc, e, e2);
            loc = token.loc;
        }
        return e;
    }

    private AST.Expression parseXorExp()
    {
        const loc = token.loc;

        auto e = parseAndExp();
        while (token.value == TOK.xor)
        {
            checkParens(TOK.xor, e);
            nextToken();
            auto e2 = parseAndExp();
            checkParens(TOK.xor, e2);
            e = new AST.XorExp(loc, e, e2);
        }
        return e;
    }

    private AST.Expression parseOrExp()
    {
        const loc = token.loc;

        auto e = parseXorExp();
        while (token.value == TOK.or)
        {
            checkParens(TOK.or, e);
            nextToken();
            auto e2 = parseXorExp();
            checkParens(TOK.or, e2);
            e = new AST.OrExp(loc, e, e2);
        }
        return e;
    }

    private AST.Expression parseAndAndExp()
    {
        const loc = token.loc;

        auto e = parseOrExp();
        while (token.value == TOK.andAnd)
        {
            nextToken();
            auto e2 = parseOrExp();
            e = new AST.LogicalExp(loc, TOK.andAnd, e, e2);
        }
        return e;
    }

    private AST.Expression parseOrOrExp()
    {
        const loc = token.loc;

        auto e = parseAndAndExp();
        while (token.value == TOK.orOr)
        {
            nextToken();
            auto e2 = parseAndAndExp();
            e = new AST.LogicalExp(loc, TOK.orOr, e, e2);
        }
        return e;
    }

    private AST.Expression parseCondExp()
    {
        const loc = token.loc;

        auto e = parseOrOrExp();
        if (token.value == TOK.question)
        {
            nextToken();
            auto e1 = parseExpression();
            check(TOK.colon);
            auto e2 = parseCondExp();
            e = new AST.CondExp(loc, e, e1, e2);
        }
        return e;
    }

    AST.Expression parseAssignExp()
    {
        AST.Expression e;
        e = parseCondExp();
        if (e is null)
            return e;

        // require parens for e.g. `t ? a = 1 : b = 2`
        // Deprecated in 2018-05.
        // @@@DEPRECATED_2.091@@@.
        if (e.op == TOK.question && !e.parens && precedence[token.value] == PREC.assign)
            dmd.errors.deprecation(e.loc, "`%s` must be surrounded by parentheses when next to operator `%s`",
                e.toChars(), Token.toChars(token.value));

        const loc = token.loc;
        switch (token.value)
        {
        case TOK.assign:
            nextToken();
            auto e2 = parseAssignExp();
            e = new AST.AssignExp(loc, e, e2);
            break;

        case TOK.addAssign:
            nextToken();
            auto e2 = parseAssignExp();
            e = new AST.AddAssignExp(loc, e, e2);
            break;

        case TOK.minAssign:
            nextToken();
            auto e2 = parseAssignExp();
            e = new AST.MinAssignExp(loc, e, e2);
            break;

        case TOK.mulAssign:
            nextToken();
            auto e2 = parseAssignExp();
            e = new AST.MulAssignExp(loc, e, e2);
            break;

        case TOK.divAssign:
            nextToken();
            auto e2 = parseAssignExp();
            e = new AST.DivAssignExp(loc, e, e2);
            break;

        case TOK.modAssign:
            nextToken();
            auto e2 = parseAssignExp();
            e = new AST.ModAssignExp(loc, e, e2);
            break;

        case TOK.powAssign:
            nextToken();
            auto e2 = parseAssignExp();
            e = new AST.PowAssignExp(loc, e, e2);
            break;

        case TOK.andAssign:
            nextToken();
            auto e2 = parseAssignExp();
            e = new AST.AndAssignExp(loc, e, e2);
            break;

        case TOK.orAssign:
            nextToken();
            auto e2 = parseAssignExp();
            e = new AST.OrAssignExp(loc, e, e2);
            break;

        case TOK.xorAssign:
            nextToken();
            auto e2 = parseAssignExp();
            e = new AST.XorAssignExp(loc, e, e2);
            break;

        case TOK.leftShiftAssign:
            nextToken();
            auto e2 = parseAssignExp();
            e = new AST.ShlAssignExp(loc, e, e2);
            break;

        case TOK.rightShiftAssign:
            nextToken();
            auto e2 = parseAssignExp();
            e = new AST.ShrAssignExp(loc, e, e2);
            break;

        case TOK.unsignedRightShiftAssign:
            nextToken();
            auto e2 = parseAssignExp();
            e = new AST.UshrAssignExp(loc, e, e2);
            break;

        case TOK.concatenateAssign:
            nextToken();
            auto e2 = parseAssignExp();
            e = new AST.CatAssignExp(loc, e, e2);
            break;

        default:
            break;
        }

        return e;
    }

    /*************************
     * Collect argument list.
     * Assume current token is ',', '$(LPAREN)' or '['.
     */
    private AST.Expressions* parseArguments()
    {
        // function call
        AST.Expressions* arguments;

        arguments = new AST.Expressions();
        const endtok = token.value == TOK.leftBracket ? TOK.rightBracket : TOK.rightParentheses;

        nextToken();

        while (token.value != endtok && token.value != TOK.endOfFile)
        {
            auto arg = parseAssignExp();
            arguments.push(arg);
            if (token.value != TOK.comma)
                break;

            nextToken(); //comma
        }

        check(endtok);

        return arguments;
    }

    /*******************************************
     */
    private AST.Expression parseNewExp(AST.Expression thisexp)
    {
        const loc = token.loc;

        nextToken();
        AST.Expressions* newargs = null;
        AST.Expressions* arguments = null;
        if (token.value == TOK.leftParentheses)
        {
            newargs = parseArguments();
        }

        // An anonymous nested class starts with "class"
        if (token.value == TOK.class_)
        {
            nextToken();
            if (token.value == TOK.leftParentheses)
                arguments = parseArguments();

            AST.BaseClasses* baseclasses = null;
            if (token.value != TOK.leftCurly)
                baseclasses = parseBaseClasses();

            Identifier id = null;
            AST.Dsymbols* members = null;

            if (token.value != TOK.leftCurly)
            {
                error("`{ members }` expected for anonymous class");
            }
            else
            {
                nextToken();
                members = parseDeclDefs(0);
                if (token.value != TOK.rightCurly)
                    error("class member expected");
                nextToken();
            }

            auto cd = new AST.ClassDeclaration(loc, id, baseclasses, members, false);
            auto e = new AST.NewAnonClassExp(loc, thisexp, newargs, cd, arguments);
            return e;
        }

        const stc = parseTypeCtor();
        auto t = parseBasicType(true);
        t = parseBasicType2(t);
        t = t.addSTC(stc);
        if (t.ty == AST.Taarray)
        {
            AST.TypeAArray taa = cast(AST.TypeAArray)t;
            AST.Type index = taa.index;
            auto edim = AST.typeToExpression(index);
            if (!edim)
            {
                error("cannot create a `%s` with `new`", t.toChars);
                return new AST.NullExp(loc);
            }
            t = new AST.TypeSArray(taa.next, edim);
        }
        else if (token.value == TOK.leftParentheses && t.ty != AST.Tsarray)
        {
            arguments = parseArguments();
        }

        auto e = new AST.NewExp(loc, thisexp, newargs, t, arguments);
        return e;
    }

    /**********************************************
     */
    private void addComment(AST.Dsymbol s, const(char)* blockComment)
    {
        if (s !is null)
            this.addComment(s, blockComment.toDString());
    }

    private void addComment(AST.Dsymbol s, const(char)[] blockComment)
    {
        if (s !is null)
        {
            s.addComment(combineComments(blockComment, token.lineComment, true));
            token.lineComment = null;
        }
    }

    /**********************************************
     * Recognize builtin @ attributes
     * Params:
     *  ident = identifier
     * Returns:
     *  storage class for attribute, 0 if not
     */
    static StorageClass isBuiltinAtAttribute(Identifier ident)
    {
        return (ident == Id.property) ? AST.STC.property :
               (ident == Id.nogc)     ? AST.STC.nogc     :
               (ident == Id.safe)     ? AST.STC.safe     :
               (ident == Id.trusted)  ? AST.STC.trusted  :
               (ident == Id.system)   ? AST.STC.system   :
               (ident == Id.live)     ? AST.STC.live     :
               (ident == Id.future)   ? AST.STC.future   :
               (ident == Id.disable)  ? AST.STC.disable  :
               0;
    }

    enum StorageClass atAttrGroup =
                AST.STC.property |
                AST.STC.nogc     |
                AST.STC.safe     |
                AST.STC.trusted  |
                AST.STC.system   |
                AST.STC.live     |
                /*AST.STC.future   |*/ // probably should be included
                AST.STC.disable;
    }

enum PREC : int
{
    zero,
    expr,
    assign,
    cond,
    oror,
    andand,
    or,
    xor,
    and,
    equal,
    rel,
    shift,
    add,
    mul,
    pow,
    unary,
    primary,
}
