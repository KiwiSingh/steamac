# steamac — официальный ARM64 SteamOS (образ Steam Frame) в ВМ на Apple Silicon

На macOS 15 (Sequoia) настоящий SteamOS от Valve для Steam Frame запускается в лёгкой ВМ на
Hypervisor.framework (libkrun) с GPU-ускорением через Venus.

```
игра (DX9/10/11) ─ DXVK (Proton 11, x86 через FEX) ─ Vulkan
   └─ гостевой Mesa Venus ─ virtio-gpu (blob, 16K-выравнивание)
        └─ libkrun ─ virglrenderer (Venus) ─ MoltenVK ─ Metal
```

Vulkan на Metal — MoltenVK из форка UTM (геометрические шейдеры, robustness2) +
`VK_EXT_depth_clip_enable` (PR #2712) + наши исправления. KosmicKrisp (Mesa Vulkan-on-Metal) не
подходит: он требует Metal 4 / macOS 26.

## Требования

- Mac на Apple Silicon, macOS 15+, ~150 ГБ свободного места (образ диска разреженный).
- Xcode 26+ (полный: его `actool` собирает иконку приложения из Icon Composer-документа), Homebrew, rustup.
- OrbStack (или Docker с arm64 и `--privileged`): ядро, Mesa и образ диска собираются в Linux-контейнерах.
- Homebrew-пакеты: `meson ninja pkg-config dtc xz lld libepoxy sshpass`.

## Сборка и запуск

```sh
./build.sh          # всё: MoltenVK, virglrenderer, libkrun, лаунчер, ядро, Mesa, диск
./run.sh            # окно с SteamOS
```

Части по отдельности: `./build.sh host`, `./build.sh guest`, либо скрипты из таблицы ниже.
Образ SteamOS скачивается с серверов Valve (подписанный RAUC-бандл), подпись и sha256 проверяются.

Параметры ВМ: `./run.sh --display 1920x1080 --cpus 10 --mem 24576` (полный список —
`work/out/steamac-vm --help`).

Плавность кадров: `./run.sh --perf-stats` (или `STEAMAC_PERF_STATS=1`) каждые 5 с пишет в терминал
интервалы кадров гостя и кадров на экране (p50/p95/p99/max, число интервалов > 25 и > 50 мс).
Подтормаживания при первом появлении нового эффекта — это компиляция шейдеров Metal (~50–100 мс на
пайплайн); результат кешируется Metal на диске, повторно эффект не тормозит, в том числе после
перезапуска ВМ. Steam сам прогревает этот кеш (Shader Pre-Caching / fossilize_replay включены
в SteamOS по умолчанию), делать ничего не нужно.

Если гость 2 с не присылает GPU-команд (virtio-gpu control queue и Venus-кольца — счётчики
`krun_gpu_get_activity`), поверх последнего кадра появляется карточка «Still working — loading or
compiling shaders…» с загрузкой CPU ВМ; если агент гостя перестал присылать heartbeat (> 5 с) —
«SteamOS is not responding…». Исчезает с первой же GPU-командой; каждый случай пишется в лог
(`stall: gpu idle 3.1 s (guest alive, …)`). С `--perf-stats` раз в 5 с добавляется строка
`perf: gpu ctrl/s=… ring/s=… longest-idle=…`. Выключается в Settings > General.

| Клавиши в окне | |
|---|---|
| Ctrl+Cmd+F | полный экран |
| Ctrl+Cmd+G | захватить / отпустить мышь вручную |
| Ctrl+Option | отпустить захваченную мышь |
| закрыть окно | выключение гостя (кнопка питания) |

Мышь (`--mouse auto`, по умолчанию): курсор SteamOS точно следует за курсором Mac. gamescope
(игровой режим) не принимает абсолютные координаты, поэтому лаунчер ведёт его относительными
сдвигами без ускорения. Когда в госте в фокусе игра (агент шлёт `focus game <appid>`), первый
щелчок захватывает мышь (относительное движение для обзора мышью), Ctrl+Option отпускает; при
возврате в Steam захват снимается сам. Меню **Mouse**:
- **Capture Mouse in This Game** — авто-захват для текущей игры (сохраняется по appid);
- **Auto-Capture Mouse in Games** — значение по умолчанию для всех игр;
- **Capture / Release Mouse Now** — то же, что Ctrl+Cmd+G.

Эти и все остальные настройки — в окне **Settings** (см. ниже), домен `es.fxgam.steamac`
(`defaults read es.fxgam.steamac`); при первом запуске они один раз копируются из прежнего домена
`dev.steamac.vm`. Metal хранит кеш шейдеров по идентификатору приложения, поэтому после смены
идентификатора первый запуск игр снова компилирует шейдеры (один «холодный» запуск).
`--auto-capture on|off` переопределяет значение по умолчанию на один запуск.
`--mouse tablet` — абсолютный планшет (для режима рабочего стола KDE, он включается и сам по
`focus desktop`), `--mouse capture` — всегда захват по щелчку.

Доступ в гостя: `ssh -p 2222 steamos@127.0.0.1`, пароль `steamos` (меняется через
`STEAMOS_PASSWORD=... scripts/build-image.sh disk`). Консоль hvc0 — в терминале, где запущен `run.sh`.

SSH включается и выключается одним переключателем: **Settings → Advanced → Enable SSH** (или
`--ssh-port N` / `--no-ssh`). Лаунчер на каждой загрузке передаёт `steamac.ssh=0|1`: при 0 порт на
Mac не открывается вовсе (gvproxy без проброса), а initramfs маскирует sshd в SteamOS. По умолчанию
SSH включён у dev-лаунчера (`work/out/steamac-vm`, `./run.sh`, порт 2222) и выключен в
`FX Steam Launcher.app` (ключ `SteamacReleaseDefaults` в Info.plist, ставит `bundle.sh`). При
включении лаунчер генерирует пароль пользователя `steamos` (20 символов, SecRandomCopyBytes),
хранит его в связке ключей отдельно для каждого диска (по GUID его GPT) и на следующей загрузке
передаёт гостю только хеш SHA-512 crypt (диск-«config payload», `steamac.config=1`; гость отвечает
`config applied`). В настройках видны пользователь, пароль (Show/Copy), готовая строка
`ssh -p … steamos@127.0.0.1`, статус «applied / will apply on next start» и **Regenerate Password**;
у dev-лаунчера пароль генерируется только кнопкой (диски Docker-сборки сохраняют `steamos`). Диски,
созданные в приложении, получают пароль только так — пароля по умолчанию у них нет. Из терминала:
`steamac-vm --ssh-password <диск>` печатает пользователя, пароль и статус.

## Окно настроек

**FX Steam Launcher → Settings…** (Cmd+, — работает и когда клавиатура у гостя). У каждого поля
подпись «applies now» (применяется сразу) или «applies on next start» (при следующем запуске ВМ).
Если изменено что-то из второй группы, внизу появляется **Restart VM to apply**: гость штатно
выключается кнопкой питания, супервизор запускает ВМ заново уже с новыми значениями (то же —
пункт меню **Restart VM**). Флаги командной строки важнее сохранённых значений, но только на этот
запуск: рядом с полем пишется «overridden by command line (--cpus 6)».

| Вкладка | Сразу | При следующем запуске |
|---|---|---|
| General | оверлей загрузки/выключения; индикатор «Still working…» при простое GPU; отчёты о сбоях (`--no-crash-reports`, см. ниже); лог статистики кадров (`--perf-stats`) | полный экран при старте |
| Display | гость следует за размером окна | источник физического размера (авто по экрану / DPI / мм — `--dpi`, `--display-mm`), частота (`--refresh`), размер окна (`--display`) |
| Mouse | авто-захват в играх; список игр (имя из `appmanifest_<appid>.acf`, Default/Auto/Off, удалить) | — |
| Controller | какой физический контроллер (GameController) ведёт виртуальный pad (первый подключённый или выбранный), A/B и X/Y местами, мёртвая зона стиков, живой тест ввода | виртуальный Xbox 360 pad (`--no-gamepad`) |
| Sound | устройство вывода (System default следует за macOS или конкретное CoreAudio-устройство), громкость/mute, буфер Low/Normal/Safe — через `krun_snd_set_*` (ищутся `dlsym`; со старым libkrun поля выключены с пояснением) | звук (`--no-sound`) |
| Advanced | — | vCPU (`--cpus`), RAM (`--mem`), SSH вкл/выкл + порт (`--ssh-port`, `--no-ssh`) и сгенерированный пароль, сеть (`--no-net`), образ диска (`--disk`), Create New Disk… |

Для тестов: `STEAMAC_DEFAULTS_DOMAIN=<домен>` подменяет домен настроек; `--selftest-settings
--selftest-out DIR` открывает окно без ВМ и пишет PNG каждой вкладки; в `--control-fifo` есть
`settings TAB`, `settings-dump PNG`, `set KEY VALUE` (как из окна), `restart`.

## FX Steam Launcher.app

`host/launcher/build.sh` (и `./build.sh host`) кроме `work/out/steamac-vm` собирает
`work/out/FX Steam Launcher.app` (`host/launcher/bundle.sh`): `es.fxgam.steamac`, библиотеки
(libkrun, libvirglrenderer, libMoltenVK, libepoxy) в `Contents/Frameworks` через `@rpath`,
в `Contents/Resources` — gvproxy, ядро `Image`, `initramfs.cpio.gz`, `steamac-layer.img`, desync и
CA Valve для создания диска (лицензии — в `Resources/licenses`), иконка: `host/launcher/AppIcon.icon`
(документ Icon Composer) `actool` компилирует в `Assets.car` (Liquid Glass на macOS 26, готовые
рендеры для macOS 15) и запасной `AppIcon.icns`;
подпись ad-hoc с entitlements hypervisor + disable-library-validation. Приложение можно
перенести в `/Applications`.

Запуск из Finder (без аргументов) берёт ядро, initramfs и слой из бандла, а диск SteamOS — из
Settings → Advanced → Disk image. По умолчанию:
`~/Library/Application Support/es.fxgam.steamac/steamos.img`, иначе `work/out/steamos.img`
репозитория (рядом с бандлом или там, где он был собран). Если диска нет — окно первого запуска:
**Create New Disk…** (см. следующий раздел) или **Use Existing Disk…** (образ используется на
месте и никогда не копируется; собирается и `scripts/build-image.sh`). Консоль гостя и лог лаунчера в этом режиме
пишутся в `~/Library/Logs/es.fxgam.steamac/steamac-vm.log`, SIGUSR1-дампы кадра — туда же.
`./run.sh` и `work/out/steamac-vm` работают как раньше (настройки из окна действуют и для них,
если не заданы флагами).

Если образ лежит на внешнем диске, при первом запуске из Finder macOS спрашивает «FX Steam
Launcher хочет получить доступ к файлам на съёмном томе» — нужно разрешить (до ответа ВМ ждёт
на открытии диска). Подпись ad-hoc, поэтому после пересборки бандла macOS может спросить снова.

## Создание диска SteamOS без Docker (Creating the SteamOS disk without Docker)

Пользователю приложения Docker не нужен: диск создаёт сам лаунчер — окно первого запуска
**Create New Disk…** или **Settings → Advanced → Create New Disk…** (ветка stable/rc/beta/preview/main,
размер home, место, пароль пользователя `steamos`; прогресс, Stop и Resume). То же без окна:

```sh
work/out/steamac-vm --create-disk ~/steamos.img [--branch stable] [--home-gib 64] [--password PW] [--keep-cache]
```

1. `https://steamdeck-atomupd.steamos.cloud/meta/holo/steamos/aarch64/vr/<ветка>.json` → свежий
   кандидат (`update_path`, `chunks_store_path`).
2. Скачивается `.raucb` (~2 МБ); CMS-подпись проверяется Security.framework только против
   закреплённого CA Valve `CN=steamdeck-images` (`scripts/keys/steamdeck-images.pem`, SHA-256 отпечаток
   зашит в код); системное хранилище доверия не используется. Свой читатель squashfs (zstd из
   закреплённого релиза zstd, `fetch-zstd.sh`) достаёт `manifest.raucm` и `rootfs.img.caibx`;
   проверяются `compatible=steamos-aarch64`, версия и размер слота.
3. Официальный desync (`fetch-desync.sh`, версия и sha256 закреплены) собирает 10-гигабайтный
   `rootfs.img` из хранилищ чанков Valve (~4,4 ГБ данных); кеш чанков —
   `~/Library/Caches/es.fxgam.steamac/desync`, частичный `<диск>.rootfs-tmp` остаётся, поэтому
   Stop/Resume (или повтор команды после Ctrl+C) продолжает с места остановки.
4. Разреженный файл диска: защитный MBR + GPT (основная и резервная, CRC32) ровно с именами,
   порядком, типами, размерами и выравниванием `scripts/steps/40-disk.sh`, случайные PARTUUID.
   За один проход `rootfs.img` хешируется (sha256 должен совпасть с подписанным манифестом) и
   ненулевые блоки по 16 КиБ пишутся в rootfs-A и rootfs-B; остальные разделы — нули. Диск
   появляется под своим именем только после всех проверок и никогда не перезаписывает файл.
5. Рядом кладётся `<диск без .img>.provision.img` — cpio newc с `provision.env` (сборка, PARTUUID,
   хеш пароля SHA-512 crypt, machine-id) и `rootfs.caibx` (формат — «Payload v1» в контракте
   провижининга). Пока этот файл есть, лаунчер подключает его только для чтения (vdc) и добавляет
   `steamac.provision=1`: initramfs форматирует esp/efi-X/var-X/home, делает fsid rootfs-B
   уникальным, пишет partsets/bootconf/bootenv/var и сообщает `provision done` — после этого лаунчер
   удаляет payload, следующие загрузки идут без него.

Место: ~14 ГБ на томе диска на время создания (потом ~9 ГБ), ~6 ГБ кеша (удаляется после успеха,
если не указан `--keep-cache`). Проверки: `work/out/steamac-vm --selftest-provision` — GPT против
диска из Docker-сборки (`work/out/steamos.img` открывается только на чтение; `--reference-disk IMG`),
CMS/squashfs против кеша `work/cache/rootfs`, cpio, SHA-512 crypt.

## Дистрибутив (DMG)

`host/launcher/dist.sh` делает из собранного `work/out/FX Steam Launcher.app` то, что выкладывается
для скачивания: `work/out/dist/FX-Steam-Launcher-<версия>.dmg` (приложение + ссылка на
`/Applications`). Копия бандла без ключа `SteamacBuildOut` (путь к этому дереву сборки)
переподписывается Developer ID с hardened runtime и secure timestamp: сначала все вложенные Mach-O
(`Frameworks/*.dylib`, вспомогательные программы в `Resources`), затем бандл с
`steamac-vm.entitlements` (hypervisor, disable-library-validation и audio-input — без него hardened
runtime молча запрещает микрофон). Приложение нотаризуется и стейплится, затем DMG подписывается,
нотаризуется и стейплится — Gatekeeper пропускает его и офлайн (остаётся обычный вопрос
«загружено из интернета» при первом запуске).

```sh
host/launcher/build.sh      # свежий бандл
host/launcher/dist.sh       # подпись, нотаризация, DMG
```

Один раз нужен профиль notarytool в связке ключей:
`xcrun notarytool store-credentials steamac-notary --apple-id <Apple ID> --team-id V25VKGTW55
--password <app-specific password>`. Переменные: `STEAMAC_SIGN_IDENTITY` (по умолчанию
единственная «Developer ID Application» в связке), `NOTARY_PROFILE` (по умолчанию `steamac-notary`);
`--no-notarize` — только подпись, для локальной проверки (скачанную копию Gatekeeper не пустит).

## Отчёты о сбоях (Sentry)

Лаунчер отправляет отчёты о сбоях и немногие ошибки на собственный сервер Sentry разработчиков
(`sentry.fxgam.es`, SDK sentry-cocoa 9.30.0 через SwiftPM). Включено по умолчанию; выключается
галочкой **Send crash reports and diagnostics** — в Settings → General, в окне первого запуска и в
окне Create SteamOS Disk (ссылка «What is sent» показывает список ниже). Выключено — SDK вообще не
запускается, сетевых соединений нет (уже сохранённые отчёты остаются на диске и не отправляются).
На один запуск: `--no-crash-reports` или `STEAMAC_SENTRY=0`.

Что отправляется:

- падения процесса-супервизора и процесса ВМ (сигнал/abort, необработанные исключения): причина,
  стеки потоков, список загруженных библиотек. Сюда попадают assert'ы Metal/MoltenVK, abort'ы
  libkrun/virglrenderer и паники Rust, вышедшие через C API libkrun. Отчёт о падении процесса ВМ
  уходит при следующем запуске ВМ;
- немногие ошибки (не чаще раза на отпечаток за процесс, общий лимит, повтор того же отпечатка — не
  раньше чем через сутки, для ошибок компиляции шейдеров — 30 дней): гостевой GPU-контекст стал
  фатальным/потеря устройства (vkr «fatal decoder state», «device lost»), ошибки компиляции
  пайплайнов MoltenVK (`[mvk-error] … compile failed`) и vkr «pipeline … creation failed on host»,
  паника Rust в libkrun (`thread … panicked at`), провал первичной настройки диска (`provision
  failed`), провал создания диска, неожиданный выход ВМ (ненулевой код или сигнал, если выключение не
  запрошено пользователем), «SteamOS is not responding» индикатора простоя;
- в каждом событии — последние ~200 строк stderr лаунчера как breadcrumbs (строки `[steamac-vm]`,
  `[mvk-*]`, предупреждения libkrun/virglrenderer, этапы загрузки) и теги: версия
  (`es.fxgam.steamac@<CFBundleShortVersionString>+<git sha>`), окружение `release` (`.app`) или
  `development`, macOS, модель Mac, GPU, vCPU/RAM, режим дисплея, UUID сборок libkrun /
  virglrenderer / MoltenVK, `MVK_PATCH_REVISION`, версия ядра, BUILD_ID SteamOS и релиз слоя (из
  строк initramfs), случайный ID установки.

Не отправляется: консоль гостя (hvc0), имя пользователя и компьютера (`/Users/<имя>` → `~`, имя и
hostname вырезаются), IP (`sendDefaultPii=false`, сервер не выводит IP), локаль/часовой пояс,
аккаунт Steam, названия игр (только App ID), файлы. Супервизор пропускает свой stderr через канал
(всё по-прежнему попадает в терминал/лог), поэтому видит и последние строки упавшего процесса ВМ.

Проверка: `--sentry-test-event` (тестовое событие из супервизора и процесса ВМ, процесс ВМ заодно
отправляет отложенный отчёт о падении и выходит), `--sentry-test-crash abort|segv|metal|panic`
(процесс ВМ падает: `abort()` внутри вызова C, `EXC_BAD_ACCESS` в `memset`, assert Metal, паника
Rust в `krun_start_enter` из-за слишком длинной командной строки ядра — для `panic` нужны `--kernel`
и, при необходимости, `--initrd`). Такие события идут с `environment=development` и тегом `test=true`.
`STEAMAC_SENTRY_DEBUG=1` печатает отладочный лог SDK (ответы сервера).

Символы: `build.sh` кладёт dSYM `steamac-vm` и библиотек бандла в `work/out/dSYMs` (libkrun,
virglrenderer и MoltenVK собраны без DWARF — там только таблицы символов). `dist.sh` загружает их и
бинарники приложения через `sentry-cli --url https://sentry.fxgam.es debug-files upload`, если заданы
`SENTRY_AUTH_TOKEN`, `SENTRY_ORG` и `SENTRY_PROJECT`; иначе пишет, что загрузка пропущена.

## Как это устроено

| Каталог | Что внутри |
|---|---|
| `host/moltenvk/` | MoltenVK utmapp `geometry-shaders` @05604465 + патчи: depth_clip_enable, YCbCr-массивы, null-дескрипторы, эмуляция геометрических шейдеров для zink/DXVK (шаг вершин, instancing, adjacency, fans, SCALED-форматы, `gl_in`), transform feedback (stream output DXVK), распределение служебных буферов, отложенное освобождение Metal-ресурсов, хеш патчей в UUID кэша конвейеров; тесты в `repro/` гоняются под валидацией Metal |
| `host/virglrenderer/` | virglrenderer UTM `macos-next` + слияние с upstream main (venus-protocol 1.1.3) + LINEAR-модификатор, импорт shm как host memory, заглушки для неудавшихся конвейеров, пересоздание отвергнутого кэша, отложенный unmap shm, QoS потоков |
| `host/libkrun/` | libkrun v1.19.6 + патчи: `VIRTIO_GPU_F_BLOB_ALIGNMENT` (16K), маска SME для M4, 2D-ресурсы без virgl, `SET_SCANOUT_BLOB`, маппинг SHM-блобов, сигнализация Venus-фенсов, логи virglrenderer, `krun_display_resize` (смена разрешения на лету), QoS vCPU/GPU-потоков |
| `host/launcher/` | `steamac-vm` (Swift/AppKit): окно на Metal, оверлей «FX STEAM LAUNCHER» с прогрессом загрузки/выключения, разрешение гостя = размер окна при постоянном DPI (EDID из физического размера экрана), клавиатура/мышь/планшет, виртуальный Xbox 360 pad из GameController.framework, сеть через gvproxy, перезапуск ВМ при reboot гостя, `--perf-stats` |
| `guest/kernel/` | Linux 7.2.9, всё встроено, 4K-страницы, выравнивание blob-узлов по 16K, Apple TSO для FEX |
| `guest/mesa/` | Venus ICD для aarch64 (Proton, gamescope, zink) и x86_64/i386 (FEX-провайдер графики) |
| `guest/initramfs/` | загрузочный этап = «загрузчик»: выбор слота A/B со счётчиком попыток, partsets, оверлеи `/etc` и `/usr`; первичная подготовка диска, созданного лаунчером (`steamac.provision=1`: статические mkfs.fat, mke2fs, btrfstune в initramfs); `steamac.ssh=0` — без SSH-сервера; config-payload лаунчера (`steamac.config=1`) — новый пароль `steamos` |
| `guest/layer/` | слой для ВМ поверх `/usr` (read-only erofs): файловый `splctl`, безопасный post-install для RAUC, `VARIANT_ID=steamdeck`, сессия gamescope на DRM, маски сервисов железа Frame, агент прогресса `fx-progress-agent` (Rust, `guest/progress-agent/`, порт virtio-console `fx.progress`), быстрые таймауты выключения, опциональная ветка клиента Steam (`/etc/steamac/steam-client-branch`) |
| `scripts/` | сборка `work/out/steamos.img`: GPT в разметке Valve (esp, efi-A/B, rootfs-A/B, var-A/B, home); `scripts/test/provision-test-disk.sh` — dev-проверка провижининга против диска из Docker |

Корневая ФС SteamOS не модифицируется: все изменения приходят из initramfs и слоя. Поэтому
официальные обновления Valve (RAUC + atomupd) ставятся в другой слот и откатываются штатно —
проверено обновлением 20260922 → 20260928 и откатом.

## Статус

Проверено:

- загрузка SteamOS до `graphical.target`, автологин, gamescope-сессия; сеть (DHCP через gvproxy,
  скачивание обновления клиента Steam 583 МБ), SSH;
- Venus в госте: `Virtio-GPU Venus (Apple M4 Max)`, Vulkan 1.4; рендер-тест (compute + clear/copy)
  и вывод на экран через KMS совпадают с эталоном попиксельно;
- все обязательные возможности DXVK из Proton 11 / DXVK 3.x видны в госте (geometryShader,
  shaderCullDistance, depthClipEnable, robustness2 + nullDescriptor, maintenance5/6, …);
- клавиатура, планшет, мышь и виртуальный Xbox 360 pad видны в SteamOS;
- обновление A→B официальным OTA и откат;
- GL через zink (glamor в Xwayland, glxgears ~60 FPS), интерфейс Steam (gamepad UI, CEF с GPU)
  отрисовывается на экране ВМ;
- вход в Steam, установка Proton 11.0-2 (ARM64) и FEX, запуск DX11-игры (Death's Door) через
  DXVK → Venus → MoltenVK;
- разрешение гостя следует за размером окна при постоянном DPI; быстрое выключение (2–4 с);
- Heroes of Might and Magic: Olden Era (Unity, DX11) — 7 минут без ошибок (офлайн-проверка).

Подтормаживания при первом проходе — компиляция Metal (~50–100 мс на новый конвейер), повторно
~1 мс. При перезагрузке после аварийного выключения initramfs проверяет и чинит FAT на esp/efi.

## Ограничения

- DirectX 12 (vkd3d-proton) не работает: MoltenVK не даёт нужных возможностей.
- Звук: virtio-snd → CoreAudio (устройство по умолчанию или выбранное в настройках), задержка ≈65 мс на встроенных
  динамиках; микрофон заявлен, но не проверен.
- Античиты, которые блокируют ВМ, не пройдут.
- `logicOp` недоступен (приватный Metal API в форке MoltenVK не собирается); zink выдаёт предупреждение.
