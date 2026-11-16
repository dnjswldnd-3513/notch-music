#!/usr/bin/perl
# 사용법: /usr/bin/perl run.pl /path/to/adapter.dylib
# Apple이 서명한 perl 안에서 adapter.dylib을 불러 재생 정보를 읽는다.
use strict;
use warnings;
use DynaLoader;

my $path = $ARGV[0] or die "adapter.dylib 경로가 필요합니다\n";
my $lib = DynaLoader::dl_load_file($path, 0) or die DynaLoader::dl_error();
my $sym = DynaLoader::dl_find_symbol($lib, "adapter_run") or die DynaLoader::dl_error();
DynaLoader::dl_install_xsub("main::adapter_run", $sym);
adapter_run();
