structure Lexer: LEX =
struct

  (** This is just to get around annoying bad syntax highlighting for SML... *)
  val backslash = #"\\" (* " *)

  (** =====================================================================
    * STATE MACHINE
    *
    * This bunch of mutually-recursive functions implements an efficient
    * state machine. Each is named `loop_<STATE_NAME>`. The arguments are
    * always
    *   `loop_XXX acc stream [args]`
    * where
    *   `acc` is a token accumulator,
    *   `stream` is the rest of the input, and
    *   `args` is a state-dependent state (haha)
    *)

  fun error acc msg =
    LexResult.Failure
      { partial = Seq.fromList (List.rev acc)
      , error = LexResult.Error.Other msg
      }

  fun success acc =
    LexResult.Success (Seq.fromList (List.rev acc))

  fun tokens src =
    let
      (** Some helpers for making source slices and tokens. *)
      fun slice (i, j) = Source.subseq src (i, j-i)
      fun mk x (i, j) = Token.make (slice (i, j)) x
      fun mkr x (i, j) = Token.reserved (slice (i, j)) x

      fun get i = Source.nth src i

      fun isEndOfFileAt s =
        s >= Source.length src

      (** This silliness lets you write almost-English like this:
        *   if is #"x" at i          then ...
        *   if check isSymbolic at i then ...
        *)
      infix 5 at
      fun f at i = f i
      fun check f i = i < Source.length src andalso f (get i)
      fun is c = check (fn c' => c = c')


      fun loop_topLevel acc s =
        if isEndOfFileAt s then
          (** DONE *)
          success acc
        else
          case get s of
            #"(" =>
              loop_afterOpenParen acc (s+1)
          | #")" =>
              loop_topLevel (mkr Token.CloseParen (s, s+1) :: acc) (s+1)
          | #"[" =>
              loop_topLevel (mkr Token.OpenSquareBracket (s, s+1) :: acc) (s+1)
          | #"]" =>
              loop_topLevel (mkr Token.CloseSquareBracket (s, s+1) :: acc) (s+1)
          | #"{" =>
              loop_topLevel (mkr Token.OpenCurlyBracket (s, s+1) :: acc) (s+1)
          | #"}" =>
              loop_topLevel (mkr Token.CloseCurlyBracket (s, s+1) :: acc) (s+1)
          | #"," =>
              loop_topLevel (mkr Token.Comma (s, s+1) :: acc) (s+1)
          | #";" =>
              loop_topLevel (mkr Token.Semicolon (s, s+1) :: acc) (s+1)
          | #"_" =>
              loop_topLevel (mkr Token.Underscore (s, s+1) :: acc) (s+1)
          | #"\"" =>
              loop_inString acc (s+1) {stringStart = s}
          | #"~" =>
              loop_afterTwiddle acc (s+1)
          | #"'" =>
              loop_alphanumId acc (s+1)
                { idStart = s
                , startsPrime = true
                , isQualified = false
                }
          | #"0" =>
              loop_afterZero acc (s+1)
          | #"." =>
              loop_afterDot acc (s+1)
          | c =>
              if LexUtils.isDecDigit c then
                loop_decIntegerConstant acc (s+1) {constStart = s}
              else if LexUtils.isSymbolic c then
                loop_symbolicId acc (s+1) {idStart = s, isQualified = false}
              else if LexUtils.isLetter c then
                loop_alphanumId acc (s+1)
                  {idStart = s, startsPrime = false, isQualified = false}
              else
                loop_topLevel acc (s+1)



      and loop_afterDot acc s =
        if (is #"." at s) andalso (is #"." at s+1) then
          loop_topLevel
            (mkr Token.DotDotDot (s-1, s+2) :: acc)
            (s+2)
        else
          error acc "unexpected '.'"



      and loop_symbolicId acc s (args as {idStart, isQualified}) =
        if check LexUtils.isSymbolic at s then
          loop_symbolicId acc (s+1) args
        else
          let
            val tok = Token.reservedOrIdentifier (slice (idStart, s))
          in
            if Token.isReserved tok andalso isQualified then
              error acc
                ( "reserved word '"
                ^ Source.toString (slice (idStart, s))
                ^ "' prefaced by qualifiers"
                )
            else
              loop_topLevel (tok :: acc) s
          end



      and loop_alphanumId acc s (args as {idStart, startsPrime, isQualified}) =
        if check LexUtils.isAlphaNumPrimeOrUnderscore at s then
          loop_alphanumId acc (s+1) args
        else
          let
            val srcHere = slice (idStart, s)
            val tok = Token.reservedOrIdentifier srcHere
          in
            if Token.isReserved tok andalso isQualified then
              error acc
                ( "reserved word '"
                ^ Source.toString srcHere
                ^ "' prefaced by qualifiers"
                )
            else if is #"." at s andalso Token.isReserved tok then
              error acc
                ( "reserved word '"
                ^ Source.toString srcHere
                ^ "' cannot be used as qualifier"
                )
            else if is #"." at s andalso startsPrime then
              error acc "structure identifiers cannot start with prime"
            else if is #"." at s then
              loop_continueLongIdentifier
                (Token.switchIdentifierToQualifier tok :: acc)
                (s+1)
            else
              loop_topLevel (tok :: acc) s
          end



      and loop_continueLongIdentifier acc s =
        if check LexUtils.isSymbolic at s then
          loop_symbolicId acc (s+1) {idStart = s, isQualified = true}
        else if check LexUtils.isLetter at s then
          loop_alphanumId acc (s+1)
            { idStart = s
            , startsPrime = false
            , isQualified = true
            }
        else
          error acc "unexpected end of qualified identifier"



      (** After seeing a twiddle, we might be at the beginning of an integer
        * constant, or we might be at the beginning of a symbolic-id.
        *
        * Note that seeing "0" next is special, because of e.g. "0x" used to
        * indicate the beginning of hex format.
        *)
      and loop_afterTwiddle acc s =
        if is #"0" at s then
          loop_afterTwiddleThenZero acc (s+1)
        else if check LexUtils.isDecDigit at s then
          loop_decIntegerConstant acc (s+1) {constStart = s - 1}
        else if check LexUtils.isSymbolic at s then
          loop_symbolicId acc (s+1) {idStart = s - 1, isQualified = false}
        else
          loop_topLevel (mk Token.Identifier (s - 1, s) :: acc) s



      (** Comes after "~0"
        * This might be the middle or end of an integer constant. We have
        * to first figure out if the integer constant is hex format.
        *)
      and loop_afterTwiddleThenZero acc s =
        if is #"x" at s andalso check LexUtils.isHexDigit at s+1 then
          loop_hexIntegerConstant acc (s+2) {constStart = s - 2}
        else if is #"." at s then
          loop_realConstantAfterDot acc (s+1) {constStart = s - 2}
        else if check LexUtils.isDecDigit at s then
          loop_decIntegerConstant acc (s+1) {constStart = s - 2}
        else
          loop_topLevel (mk Token.IntegerConstant (s - 2, s) :: acc) s



      (** After seeing "0", we're certainly at the beginning of some sort
        * of numeric constant. We need to figure out if this is an integer or
        * a word, and if it is hex or decimal format.
        *)
      and loop_afterZero acc s =
        if is #"x" at s andalso check LexUtils.isHexDigit at s+1 then
          loop_hexIntegerConstant acc (s+2) {constStart = s - 1}
        else if is #"w" at s then
          loop_afterZeroDubya acc (s+1)
        else if is #"." at s then
          loop_realConstantAfterDot acc (s+1) {constStart = s - 1}
        else if check LexUtils.isDecDigit at s then
          loop_decIntegerConstant acc (s+1) {constStart = s - 1}
        else
          loop_topLevel (mk Token.IntegerConstant (s-1, s) :: acc) s



      and loop_decIntegerConstant acc s (args as {constStart}) =
        if check LexUtils.isDecDigit at s then
          loop_decIntegerConstant acc (s+1) args
        else if is #"." at s then
          loop_realConstantAfterDot acc (s+1) args
        else
          loop_topLevel (mk Token.IntegerConstant (constStart, s) :: acc) s



      (** Immediately after the dot, we need to see at least one decimal digit *)
      and loop_realConstantAfterDot acc s (args as {constStart}) =
        if check LexUtils.isDecDigit at s then
          loop_realConstant acc (s+1) args
        else
          error acc ("unexpected end of real constant")


      (** Parsing the remainder of a real constant. This is already after the
        * dot, because the front of the real constant was already parsed as
        * an integer constant.
        *)
      and loop_realConstant acc s (args as {constStart}) =
        if check LexUtils.isDecDigit at s then
          loop_realConstant acc (s+1) args
        else if  is #"E" at s  orelse  is #"e" at s  then
          loop_realConstantAfterExponent acc (s+1) args
        else
          loop_topLevel
            (mk Token.RealConstant (constStart, s) :: acc)
            s



      and loop_realConstantAfterExponent acc s args =
        error acc "real constants with exponents not supported yet"



      and loop_hexIntegerConstant acc s (args as {constStart}) =
        if check LexUtils.isHexDigit at s then
          loop_hexIntegerConstant acc (s+1) args
        else
          loop_topLevel (mk Token.IntegerConstant (constStart, s) :: acc) s



      and loop_decWordConstant acc s (args as {constStart}) =
        if check LexUtils.isDecDigit at s then
          loop_decWordConstant acc (s+1) args
        else
          loop_topLevel (mk Token.WordConstant (constStart, s) :: acc) s



      and loop_hexWordConstant acc s (args as {constStart}) =
        if check LexUtils.isHexDigit at s then
          loop_hexWordConstant acc (s+1) args
        else
          loop_topLevel (mk Token.WordConstant (constStart, s) :: acc) s



      (** Comes after "0w"
        * It might be tempting to think that this is certainly a word constant,
        * but that's not necessarily true. Here's some possibilities:
        *   0w5       -- word constant 5
        *   0wx5      -- word constant 5, in hex format
        *   0w        -- integer constant 0 followed by alphanum-id "w"
        *   0wx       -- integer constant 0 followed by alphanum-id "wx"
        *)
      and loop_afterZeroDubya acc s =
        if is #"x" at s andalso check LexUtils.isHexDigit at s+1 then
          loop_hexWordConstant acc (s+2) {constStart = s - 2}
        else if check LexUtils.isDecDigit at s then
          loop_decWordConstant acc (s+1) {constStart = s - 2}
        else
          let
            val zeroIntConstant =
              mk Token.IntegerConstant (s - 2, s - 1)
          in
            if isEndOfFileAt s then
              (** A funny edge case. Need to parse the "0" as an integer
                * constant, and the "w" as an identifier. To get the "w", we
                * back up to s-1 and continue as an alphanumId.
                *)
              loop_alphanumId (zeroIntConstant :: acc) (s-1)
                  { idStart = s-1
                  , startsPrime = false
                  , isQualified = false
                  }
            else
              loop_topLevel (zeroIntConstant :: acc) (s-1)
          end



      (** An open-paren could just be a normal paren, or it could be the
        * start of a comment.
        *)
      and loop_afterOpenParen acc s =
        if is #"*" at s then
          loop_inComment acc (s+1) {commentStart = s - 1, nesting = 1}
        else
          loop_topLevel (mkr Token.OpenParen (s - 1, s) :: acc) s



      and loop_inString acc s (args as {stringStart}) =
        if is backslash at s then
          loop_inStringEscapeSequence acc (s+1) args
        else if is #"\"" at s then
          loop_topLevel
            (mk Token.StringConstant (stringStart, s+1) :: acc)
            (s+1)
        else if not (check Char.isPrint at s) then
          error acc ("non-printable character at " ^ Int.toString s)
        else if isEndOfFileAt s then
          error acc ("unclosed string starting at " ^ Int.toString stringStart)
        else
          loop_inString acc (s+1) args



      (** Inside a string, immediately after a backslash *)
      and loop_inStringEscapeSequence acc s (args as {stringStart}) =
        if check LexUtils.isValidSingleEscapeChar at s then
          loop_inString acc (s+1) args
        else if check LexUtils.isValidFormatEscapeChar at s then
          loop_inStringFormatEscapeSequence acc (s+1) args
        else if is #"^" at s then
          loop_inStringControlEscapeSequence acc (s+1) args
        else if is #"u" at s then
          loop_inStringFourDigitEscapeSequence acc (s+1) args
        else if check LexUtils.isDecDigit at s then
          (** Note the `s` instead of `s+1`... intentional. *)
          loop_inStringThreeDigitEscapeSequence acc s args
        else if isEndOfFileAt s then
          error acc ("unclosed string starting at " ^ Int.toString stringStart)
        else
          loop_inString acc s args



      (** In a string, expecting to see \ddd
        * with s immediately after the backslash
        *)
      and loop_inStringThreeDigitEscapeSequence acc s args =
        if
          check LexUtils.isDecDigit at s andalso
          check LexUtils.isDecDigit at s+1 andalso
          check LexUtils.isDecDigit at s+2
        then
          loop_inString acc (s+3) args
        else
          error acc ("in string, expected escape sequence \\ddd but found"
                     ^ Source.toString (slice (s-1, s+3)))



      (** In a string, expecting to see \uxxxx
        * with s immediately after the u
        *)
      and loop_inStringFourDigitEscapeSequence acc s args =
        if
          check LexUtils.isHexDigit at s andalso
          check LexUtils.isHexDigit at s+1 andalso
          check LexUtils.isHexDigit at s+2 andalso
          check LexUtils.isHexDigit at s+3
        then
          loop_inString acc (s+4) args
        else
          error acc ("in string, expected escape sequence \\uxxxx but found: "
                     ^ Source.toString (slice (s-2, s+4)))



      (** Inside a string, expecting to see \^c
        * with s immediately after the ^
        *)
      and loop_inStringControlEscapeSequence acc s (args as {stringStart}) =
        if check LexUtils.isValidControlEscapeChar at s then
          loop_inStringEscapeSequence acc (s+1) args
        else
          error acc ("invalid control escape sequence at " ^ Int.toString s)



      (** Inside a string, expecting to be inside a \f...f\
        * where each f is a format character (space, newline, tab, etc.)
        *)
      and loop_inStringFormatEscapeSequence acc s (args as {stringStart}) =
        if is backslash at s then
          loop_inString acc (s+1) args
        else if check LexUtils.isValidFormatEscapeChar at s then
          loop_inStringFormatEscapeSequence acc (s+1) args
        else
          error acc ("invalid format escape sequence at " ^ Int.toString s)



      (** Inside a comment that started at `commentStart`
        * `nesting` is always >= 0 and indicates how many open-comments we've seen.
        *)
      and loop_inComment acc s {commentStart, nesting} =
        if nesting = 0 then
          loop_topLevel (mk Token.Comment (commentStart, s) :: acc) s
        else if is #"(" at s andalso is #"*" at s+1 then
          loop_inComment acc (s+2) {commentStart=commentStart, nesting=nesting+1}
        else if is #"*" at s andalso is #")" at s+1 then
          loop_inComment acc (s+2) {commentStart=commentStart, nesting=nesting-1}
        else if isEndOfFileAt s then
          error acc ("unclosed comment starting at " ^ Int.toString commentStart)
        else
          loop_inComment acc (s+1) {commentStart=commentStart, nesting=nesting}



    in
      loop_topLevel [] 0
    end

end