{ lib, beamPackages, overrides ? (x: y: {}) }:

let
  buildRebar3 = lib.makeOverridable beamPackages.buildRebar3;
  buildMix = lib.makeOverridable beamPackages.buildMix;
  buildErlangMk = lib.makeOverridable beamPackages.buildErlangMk;

  self = packages // (overrides self packages);

  packages = with beamPackages; with self; {
    benchee = buildMix rec {
      name = "benchee";
      version = "1.5.0";

      src = fetchHex {
        pkg = "benchee";
        version = "${version}";
        sha256 = "5b075393aea81b8ae74eadd1c28b1d87e8a63696c649d8293db7c4df3eb67535";
      };

      beamDeps = [ deep_merge statistex ];
    };

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

    deep_merge = buildMix rec {
      name = "deep_merge";
      version = "1.0.0";

      src = fetchHex {
        pkg = "deep_merge";
        version = "${version}";
        sha256 = "ce708e5f094b9cd4e8f2be4f00d2f4250c4095be93f8cd6d018c753894885430";
      };

      beamDeps = [];
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

    global_flags = buildRebar3 rec {
      name = "global_flags";
      version = "1.0.0";

      src = fetchHex {
        pkg = "global_flags";
        version = "${version}";
        sha256 = "85d944cecd0f8f96b20ce70b5b16ebccedfcd25e744376b131e89ce61ba93176";
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

    local_cluster = buildMix rec {
      name = "local_cluster";
      version = "2.1.0";

      src = fetchHex {
        pkg = "local_cluster";
        version = "${version}";
        sha256 = "dc1c3abb6fef00198dd53c855b39ea80c55b3a8059d8d9f17d50da46b1e3b858";
      };

      beamDeps = [ global_flags ];
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

    snabbkaffe = buildRebar3 rec {
      name = "snabbkaffe";
      version = "1.0.10";

      src = fetchHex {
        pkg = "snabbkaffe";
        version = "${version}";
        sha256 = "70a98df36ae756908d55b5770891d443d63c903833e3e87d544036e13d4fac26";
      };

      beamDeps = [];
    };

    statistex = buildMix rec {
      name = "statistex";
      version = "1.1.0";

      src = fetchHex {
        pkg = "statistex";
        version = "${version}";
        sha256 = "f5950ea26ad43246ba2cce54324ac394a4e7408fdcf98b8e230f503a0cba9cf5";
      };

      beamDeps = [];
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

