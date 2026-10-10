#!/bin/sh
set -eu
export DOTNET_CLI_HOME=/work/cache/dotnet-home
export NUGET_PACKAGES=/work/cache/dotnet-nuget
export DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1
export DOTNET_CLI_TELEMETRY_OPTOUT=1
BUILD=/work/cache/asset-table-source
mkdir -p "$BUILD"
cp -a /src/guest/asset-table-builder/. "$BUILD/"
dotnet restore "$BUILD/AssetTableBuilder.csproj" --locked-mode -r linux-arm64
dotnet publish --no-restore "$BUILD/AssetTableBuilder.csproj" -c Release -r linux-arm64 \
    --self-contained true -p:PublishSingleFile=true -p:InvariantGlobalization=true \
    -o /work/cache/asset-table-builder

/work/cache/asset-table-builder/AssetTableBuilder --self-test
