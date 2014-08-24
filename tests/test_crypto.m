%-----------------------------------------------------------------------------%

:- module test_crypto.
:- interface.

:- import_module io.

:- pred main(io::di, io::uo) is det.

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

:- implementation.

:- import_module list.
:- import_module maybe.
:- import_module pair.
:- import_module pretty_printer.

:- import_module data.
:- import_module gmime.
:- import_module gmime_adaptor.
:- import_module gpgme.
:- import_module gpgme.decrypt.
:- import_module gpgme.gmime.
:- import_module gpgme.verify.

:- type op
    --->    decrypt(string)
    ;       verify(string, string).

%-----------------------------------------------------------------------------%

main(!IO) :-
    io.command_line_arguments(Args, !IO),
    ( Args = ["--decrypt", FileName] ->
        read_file_as_string(FileName, ResRead, !IO),
        (
            ResRead = ok(CipherText),
            main_1(decrypt(CipherText), !IO)
        ;
            ResRead = error(Error),
            report_error(Error, !IO)
        )
    ; Args = ["--verify", SigFileName, TextFileName] ->
        read_file_as_string(SigFileName, ResSig, !IO),
        read_file_as_string(TextFileName, ResText, !IO),
        (
            ResSig = ok(Sig),
            ResText = ok(Text)
        ->
            main_1(verify(Sig, Text), !IO)
        ;
            report_error("error reading files", !IO)
        )
    ;
        report_error("bad arguments", !IO)
    ).

:- pred main_1(op::in, io::di, io::uo) is det.

main_1(Op, !IO) :-
    g_mime_init(!IO),
    gpgme_init(!IO),
    gpgme_engine_check_version(openpgp, ResGpgme, !IO),
    (
        ResGpgme = ok,
        gpgme_new(ResContext, !IO),
        (
            ResContext = ok(Context),
            gpgme_set_protocol(Context, openpgp, ResProto, !IO),
            (
                ResProto = ok,
                main_2(Context, Op, !IO)
            ;
                ResProto = error(Error),
                report_error(Error, !IO)
            ),
            gpgme_release(Context, !IO)
        ;
            ResContext = error(Error),
            report_error(Error, !IO)
        )
    ;
        ResGpgme = error(Error),
        report_error(Error, !IO)
    ).

:- pred main_2(ctx::in, op::in, io::di, io::uo) is det.

main_2(Ctx, Op, !IO) :-
    Op = decrypt(CipherText),
    decrypt(Ctx, CipherText, Res, !IO),
    (
        Res = ok(DecryptResult - Part),
        write_string("DecryptResult:\n", !IO),
        write_doc(format(DecryptResult), !IO),
        write_string("\n\nPart:\n", !IO),
        write_doc(format(Part), !IO),
        write_string("\n", !IO)
    ;
        Res = error(Error),
        report_error(Error, !IO)
    ).

main_2(Ctx, Op, !IO) :-
    Op = verify(Sig, SignedText),
    verify(Ctx, Sig, SignedText, Res, !IO),
    (
        Res = ok(VerifyResult),
        write_string("VerifyResult:\n", !IO),
        write_doc(format(VerifyResult), !IO),
        write_string("\n", !IO)
    ;
        Res = error(Error),
        report_error(Error, !IO)
    ).

%-----------------------------------------------------------------------------%

:- pred decrypt(ctx::in, string::in,
    maybe_error(pair(decrypt_result, part))::out, io::di, io::uo) is det.

decrypt(Ctx, InputString, Res, !IO) :-
    gpgme_data_new_from_string(InputString, ResCipher, !IO),
    (
        ResCipher = ok(Cipher),
        stream_mem_new(PlainStream, !IO),
        gpgme_data_new_from_gmime_stream(PlainStream, ResPlain, !IO),
        (
            ResPlain = ok(Plain),
            gpgme_op_decrypt(Ctx, Cipher, Plain, ResDecrypt, !IO),
            gpgme_data_release(Plain, !IO),
            (
                ResDecrypt = ok(DecryptResult),
                seek_start(PlainStream, ResSeek, !IO),
                (
                    ResSeek = ok,
                    parser_new_with_stream(PlainStream, Parser, !IO),
                    construct_message(Parser, MaybeMessage, !IO),
                    parser_unref(Parser, !IO),
                    (
                        MaybeMessage = yes(Message),
                        message_to_part(Message, Part, !IO),
                        message_unref(Message, !IO),
                        Res = ok(DecryptResult - Part)
                    ;
                        MaybeMessage = no,
                        Res = error("could not parse message")
                    )
                ;
                    ResSeek = error(Error),
                    Res = error(Error)
                )
            ;
                ResDecrypt = error(Error),
                Res = error(Error)
            )
        ;
            ResPlain = error(Error),
            Res = error(Error)
        ),
        stream_unref(PlainStream, !IO),
        gpgme_data_release(Cipher, !IO)
    ;
        ResCipher = error(Error),
        Res = error(Error)
    ).

%-----------------------------------------------------------------------------%

:- pred verify(ctx::in, string::in, string::in,
    maybe_error(verify_result)::out, io::di, io::uo) is det.

verify(Ctx, Sig, SignedText, Res, !IO) :-
    gpgme_data_new_from_string(Sig, ResSigData, !IO),
    (
        ResSigData = ok(SigData),
        gpgme_data_new_from_string(SignedText, ResSignedTextData, !IO),
        (
            ResSignedTextData = ok(SignedTextData),
            gpgme_op_verify_detached(Ctx, SigData, SignedTextData, Res, !IO),
            gpgme_data_release(SignedTextData, !IO)
        ;
            ResSignedTextData = error(Error),
            Res = error(Error)
        ),
        gpgme_data_release(SigData, !IO)
    ;
        ResSigData = error(Error),
        Res = error(Error)
    ).

%-----------------------------------------------------------------------------%

:- pred read_file_as_string(string::in, maybe_error(string)::out,
    io::di, io::uo) is det.

read_file_as_string(FileName, Res, !IO) :-
    io.open_input(FileName, ResOpen, !IO),
    (
        ResOpen = ok(Stream),
        io.read_file_as_string(Stream, ResRead, !IO),
        (
            ResRead = ok(String),
            Res = ok(String)
        ;
            ResRead = error(_, Error),
            Res = error(error_message(Error))
        ),
        io.close_input(Stream, !IO)
    ;
        ResOpen = error(Error),
        Res = error(error_message(Error))
    ).

:- pred report_error(string::in, io::di, io::uo) is det.

report_error(Error, !IO) :-
    io.stderr_stream(Stream, !IO),
    io.write_string(Stream, Error, !IO),
    io.nl(Stream, !IO),
    io.set_exit_status(1, !IO).

%-----------------------------------------------------------------------------%
% vim: ft=mercury ts=4 sts=4 sw=4 et
