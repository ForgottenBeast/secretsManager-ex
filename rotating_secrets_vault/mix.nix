{ lib, beamPackages, overrides ? (x: y: {}) }:

let
  buildRebar3 = lib.makeOverridable beamPackages.buildRebar3;
  buildMix = lib.makeOverridable beamPackages.buildMix;
  buildErlangMk = lib.makeOverridable beamPackages.buildErlangMk;

  self = packages // (overrides self packages);

  packages = with beamPackages; with self; {
    bunt = buildMix rec {
      name = "bunt";
      version = "1.0.0";

      src = fetchHex {
        pkg = "bunt";
        version = "${version}";
        sha256 = "dc5f86aa08a5f6fa6b8096f0735c4e76d54ae5c9fa2c143e5a1fc7c1cd9bb6b5";
      };

      beamDeps = [];
    };

    credo = buildMix rec {
      name = "credo";
      version = "1.7.18";

      src = fetchHex {
        pkg = "credo";
        version = "${version}";
        sha256 = "a189d164685fd945809e862fe76a7420c4398fa288d76257662aecb909d6b3e5";
      };

      beamDeps = [ bunt file_system jason ];
    };

    dialyxir = buildMix rec {
      name = "dialyxir";
      version = "1.4.7";

      src = fetchHex {
        pkg = "dialyxir";
        version = "${version}";
        sha256 = "b34527202e6eb8cee198efec110996c25c5898f43a4094df157f8d28f27d9efe";
      };

      beamDeps = [ erlex ];
    };

    earmark_parser = buildMix rec {
      name = "earmark_parser";
      version = "1.4.44";

      src = fetchHex {
        pkg = "earmark_parser";
        version = "${version}";
        sha256 = "4778ac752b4701a5599215f7030989c989ffdc4f6df457c5f36938cc2d2a2750";
      };

      beamDeps = [];
    };

    erlex = buildMix rec {
      name = "erlex";
      version = "0.2.8";

      src = fetchHex {
        pkg = "erlex";
        version = "${version}";
        sha256 = "9d66ff9fedf69e49dc3fd12831e12a8a37b76f8651dd21cd45fcf5561a8a7590";
      };

      beamDeps = [];
    };

    ex_doc = buildMix rec {
      name = "ex_doc";
      version = "0.40.1";

      src = fetchHex {
        pkg = "ex_doc";
        version = "${version}";
        sha256 = "bcef0e2d360d93ac19f01a85d58f91752d930c0a30e2681145feea6bd3516e00";
      };

      beamDeps = [ earmark_parser makeup_elixir makeup_erlang ];
    };

    file_system = buildMix rec {
      name = "file_system";
      version = "1.1.1";

      src = fetchHex {
        pkg = "file_system";
        version = "${version}";
        sha256 = "7a15ff97dfe526aeefb090a7a9d3d03aa907e100e262a0f8f7746b78f8f87a5d";
      };

      beamDeps = [];
    };

    finch = buildMix rec {
      name = "finch";
      version = "0.21.0";

      src = fetchHex {
        pkg = "finch";
        version = "${version}";
        sha256 = "87dc6e169794cb2570f75841a19da99cfde834249568f2a5b121b809588a4377";
      };

      beamDeps = [ mime mint nimble_options nimble_pool telemetry ];
    };

    hpax = buildMix rec {
      name = "hpax";
      version = "1.0.3";

      src = fetchHex {
        pkg = "hpax";
        version = "${version}";
        sha256 = "8eab6e1cfa8d5918c2ce4ba43588e894af35dbd8e91e6e55c817bca5847df34a";
      };

      beamDeps = [];
    };

    jason = buildMix rec {
      name = "jason";
      version = "1.4.4";

      src = fetchHex {
        pkg = "jason";
        version = "${version}";
        sha256 = "c5eb0cab91f094599f94d55bc63409236a8ec69a21a67814529e8d5f6cc90b3b";
      };

      beamDeps = [];
    };

    makeup = buildMix rec {
      name = "makeup";
      version = "1.2.1";

      src = fetchHex {
        pkg = "makeup";
        version = "${version}";
        sha256 = "d36484867b0bae0fea568d10131197a4c2e47056a6fbe84922bf6ba71c8d17ce";
      };

      beamDeps = [ nimble_parsec ];
    };

    makeup_elixir = buildMix rec {
      name = "makeup_elixir";
      version = "1.0.1";

      src = fetchHex {
        pkg = "makeup_elixir";
        version = "${version}";
        sha256 = "7284900d412a3e5cfd97fdaed4f5ed389b8f2b4cb49efc0eb3bd10e2febf9507";
      };

      beamDeps = [ makeup nimble_parsec ];
    };

    makeup_erlang = buildMix rec {
      name = "makeup_erlang";
      version = "1.0.3";

      src = fetchHex {
        pkg = "makeup_erlang";
        version = "${version}";
        sha256 = "953297c02582a33411ac6208f2c6e55f0e870df7f80da724ed613f10e6706afd";
      };

      beamDeps = [ makeup ];
    };

    mime = buildMix rec {
      name = "mime";
      version = "2.0.7";

      src = fetchHex {
        pkg = "mime";
        version = "${version}";
        sha256 = "6171188e399ee16023ffc5b76ce445eb6d9672e2e241d2df6050f3c771e80ccd";
      };

      beamDeps = [];
    };

    mint = buildMix rec {
      name = "mint";
      version = "1.7.1";

      src = fetchHex {
        pkg = "mint";
        version = "${version}";
        sha256 = "fceba0a4d0f24301ddee3024ae116df1c3f4bb7a563a731f45fdfeb9d39a231b";
      };

      beamDeps = [ hpax ];
    };

    mox = buildMix rec {
      name = "mox";
      version = "1.2.0";

      src = fetchHex {
        pkg = "mox";
        version = "${version}";
        sha256 = "c7b92b3cc69ee24a7eeeaf944cd7be22013c52fcb580c1f33f50845ec821089a";
      };

      beamDeps = [ nimble_ownership ];
    };

    nimble_options = buildMix rec {
      name = "nimble_options";
      version = "1.1.1";

      src = fetchHex {
        pkg = "nimble_options";
        version = "${version}";
        sha256 = "821b2470ca9442c4b6984882fe9bb0389371b8ddec4d45a9504f00a66f650b44";
      };

      beamDeps = [];
    };

    nimble_ownership = buildMix rec {
      name = "nimble_ownership";
      version = "1.0.2";

      src = fetchHex {
        pkg = "nimble_ownership";
        version = "${version}";
        sha256 = "098af64e1f6f8609c6672127cfe9e9590a5d3fcdd82bc17a377b8692fd81a879";
      };

      beamDeps = [];
    };

    nimble_parsec = buildMix rec {
      name = "nimble_parsec";
      version = "1.4.2";

      src = fetchHex {
        pkg = "nimble_parsec";
        version = "${version}";
        sha256 = "4b21398942dda052b403bbe1da991ccd03a053668d147d53fb8c4e0efe09c973";
      };

      beamDeps = [];
    };

    nimble_pool = buildMix rec {
      name = "nimble_pool";
      version = "1.1.0";

      src = fetchHex {
        pkg = "nimble_pool";
        version = "${version}";
        sha256 = "af2e4e6b34197db81f7aad230c1118eac993acc0dae6bc83bac0126d4ae0813a";
      };

      beamDeps = [];
    };

    plug = buildMix rec {
      name = "plug";
      version = "1.19.1";

      src = fetchHex {
        pkg = "plug";
        version = "${version}";
        sha256 = "560a0017a8f6d5d30146916862aaf9300b7280063651dd7e532b8be168511e62";
      };

      beamDeps = [ mime plug_crypto telemetry ];
    };

    plug_crypto = buildMix rec {
      name = "plug_crypto";
      version = "2.1.1";

      src = fetchHex {
        pkg = "plug_crypto";
        version = "${version}";
        sha256 = "6470bce6ffe41c8bd497612ffde1a7e4af67f36a15eea5f921af71cf3e11247c";
      };

      beamDeps = [];
    };

    req = buildMix rec {
      name = "req";
      version = "0.5.17";

      src = fetchHex {
        pkg = "req";
        version = "${version}";
        sha256 = "0b8bc6ffdfebbc07968e59d3ff96d52f2202d0536f10fef4dc11dc02a2a43e39";
      };

      beamDeps = [ finch jason mime plug ];
    };

    stream_data = buildMix rec {
      name = "stream_data";
      version = "1.3.0";

      src = fetchHex {
        pkg = "stream_data";
        version = "${version}";
        sha256 = "3cc552e286e817dca43c98044c706eec9318083a1480c52ae2688b08e2936e3c";
      };

      beamDeps = [];
    };

    telemetry = buildRebar3 rec {
      name = "telemetry";
      version = "1.4.1";

      src = fetchHex {
        pkg = "telemetry";
        version = "${version}";
        sha256 = "2172e05a27531d3d31dd9782841065c50dd5c3c7699d95266b2edd54c2dafa1c";
      };

      beamDeps = [];
    };
  };
in self

