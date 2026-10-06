# steamac — официальный ARM64 SteamOS (образ Steam Frame) в ВМ на Apple Silicon

[English](README.md) · **Русский**

На macOS 15 (Sequoia) настоящий SteamOS от Valve для Steam Frame запускается в лёгкой ВМ на
Hypervisor.framework (libkrun) с GPU-ускорением через Venus.

```
игра (DX9/10/11) ─ DXVK (Proton 11, x86 через FEX) ─ Vulkan
   └─ гостевой Mesa Venus ─ virtio-gpu (blob, 16K-выравнивание)
        └─ libkrun ─ virglrenderer (Venus) ─ MoltenVK | KosmicKrisp ─ Metal
```

Vulkan на Metal — по умолчанию MoltenVK из форка UTM (геометрические шейдеры, robustness2) +
`VK_EXT_depth_clip_enable` (PR #2712) + наши исправления. KosmicKrisp (Vulkan-драйвер Mesa на
Metal 4) — экспериментальная альтернатива на macOS 26+ (см. «Vulkan-драйвер»).

## Требования

- Mac на Apple Silicon, macOS 15+, ~150 ГБ свободного места (образ диска разреженный).
- Xcode 26+ (полный: его `actool` собирает иконку приложения из Icon Composer-документа), Homebrew, rustup.
- KosmicKrisp (необязательно, альтернативный Vulkan-драйвер): собирается только на macOS 26+;
  `host/kosmickrisp/build.sh` сам ставит Homebrew-зависимости (`llvm spirv-llvm-translator spirv-tools vulkan-loader glslang`).
- OrbStack (или Docker с arm64 и `--privileged`): ядро, Mesa и образ диска собираются в Linux-контейнерах.
- Homebrew-пакеты: `meson ninja pkg-config dtc xz lld libepoxy sshpass go` (`go`: лицензии вложенных gvproxy/desync).

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
перезапуска игры или ВМ (замер через Venus: 102 мс → 0,95 мс на пайплайн в новом процессе).

Shader Pre-Caching Steam и «Allow background processing of Vulkan shaders» (Settings → Downloads) в ВМ
по умолчанию включены. Именно Pre-Caching приносит Proton транскодированные видео роликов: Steam
скачивает их для каждой игры (`steamapps/shadercache/<appid>/transcoded_video.foz`, например 836 МБ
для Heroes of Might and Magic: Olden Era, 3,8 ГБ для Diplomacy is Not an Option) и передаёт Proton
`STEAM_COMPAT_TRANSCODED_MEDIA_PATH`, а Proton проигрывает их вместо видео, которые не декодирует сам;
с выключенным Pre-Caching такие ролики показываются заглушкой. Собственный кеш DXVK (DXVK 2.7) лежит
в Wine-префиксе игры и работает в любом случае. Цена: каждый пайплайн, который обрабатывает
fossilize_replay Steam, компилирует Metal на Mac (~70–100 мс), а Steam обрабатывает заново после
своих обновлений шейдеров для игры и, для всех игр, после обновления лаунчера, меняющего MoltenVK
(идентичность драйвера Venus — хеш `pipelineCacheUUID` MoltenVK). Фоновая обработка делает большую
часть этого, пока Steam простаивает; остаток виден как «Processing Vulkan shaders» при запуске игры,
его можно пропустить кнопкой **Skip**. Выключить: Steam → Settings → Downloads → Enable Shader
Pre-caching (и/или Allow background processing of Vulkan shaders).

Штатный Steam держит фоновую обработку выключенной (отсутствующий в
`~/.local/share/Steam/config/config.vdf` `EnableShaderBackgroundProcessing` читается как 0). Перед
стартом Steam `/usr/lib/steamac/steam-shader-defaults` (ExecStartPre `steam.service`) пишет в блок
`ShaderCacheManager` `"EnableShaderBackgroundProcessing" "1"`, если значения там ещё нет, — один раз
на установку Steam (метка `config/steamac-shader-defaults`), поэтому выбор в настройках Steam
сохраняется. Лаунчер 1.4 выключал обе настройки (`"DisableShaderCache" "1"`,
`"EnableShaderBackgroundProcessing" "0"`); при первом старте Steam после обновления скрипт один раз
включает обе обратно, но только если там всё ещё ровно эти значения.

SteamOS берёт часовой пояс Mac (Settings > General **Use the Mac's time zone**, по умолчанию вкл.,
применяется при следующем запуске). При каждой загрузке лаунчер добавляет в cmdline ядра
`steamac.tz=<IANA-пояс Mac>` (`TimeZone.current`), а initramfs направляет на него `/etc/localtime`
(его используют `timedatectl`, настройка Time zone в Steam через `steamos-set-timezone` и часы Steam).
Пояс следует за Mac, пока его не изменят внутри SteamOS или Steam: последний применённый пояс
хранится в `/etc/steamac/mac-timezone`, и если текущий от него отличается, это выбор пользователя, и
он сохраняется (пока снова не совпадёт с поясом Mac). С выключенной настройкой ничего не трогается.
12/24-часовой формат часов Steam с Mac не берётся: Steam хранит его для аккаунта (Settings → Time and
date → 24-hour clock).

Прогресс загрузки и выключения не пропадает до `ready`: первый клик или клавиша в окне сворачивает
полноэкранный оверлей в плашку внизу по центру (этап, процент, полоска, строка деталей вроде
`378 / 564 MB · 1.9 MB/s`; ввод проходит в гостя). Клик по плашке или View → Show Boot Progress
разворачивает его обратно; с выключенным оверлеем (Settings > General) сразу показывается плашка.
Пока идёт подготовка нового диска или загрузка / установка клиента Steam, клик и клавиши оверлей не
сворачивают, а свёрнутый кликом раньше оверлей разворачивается сам (`overlay: expanded for
steam-download`); свёрнутый через View → Show Boot Progress остаётся плашкой до `ready`.
Заголовок окна до `ready` повторяет этап: «FX Steam Launcher — Downloading Steam update 70%»,
«— Starting Steam…», «— Shutting down…». В лог: `overlay: collapsed to pill (click)` /
`expanded from pill`. После `ready`, если в окне ≥ 3 с нет картинки (scanout выключен или после его
установки/смены размера не пришло ни одного кадра) или показанный кадр ≥ 5 с чёрный (разреженная
выборка 64 × 40 точек, яркость < 8/255 у ≥ 99,5 %, не чаще 4 раз в секунду, ~3 мкс), а фокус не в
игре и гость не спит / не на паузе / не приостановлен, плашка пишет «Waiting for SteamOS to draw…»
с причиной, heartbeat агента и CPU ВМ; исчезает с первым нечёрным кадром (`no-picture: shown after
5.0 s (black picture …)` / `hidden after … (first non-black frame)`). Проверка:
`work/out/steamac-vm --selftest-pill --selftest-out DIR`.

Пока в фокусе игра (`focus game <appid>`), если гость 2 с не присылает GPU-команд (virtio-gpu
control queue и Venus-кольца — счётчики `krun_gpu_get_activity`), поверх последнего кадра появляется
карточка «Still working — loading or compiling shaders…» с загрузкой CPU ВМ; если вдобавок агент
гостя перестал присылать heartbeat (> 5 с) — «SteamOS is not responding…» (это — при любом фокусе).
Простаивающий интерфейс Steam GPU-команд не шлёт минутами и индикатор не вызывает. Исчезает с первой
же GPU-командой или при уходе фокуса из игры; каждый случай пишется в лог (`stall: gpu idle 3.1 s
(guest alive, …)`). С `--perf-stats` раз в 5 с добавляется строка `perf: gpu ctrl/s=… ring/s=…
longest-idle=…`. Выключается в Settings > General. Агент живёт в каждой сессии gamescope (игровой
режим и режим рабочего стола): когда сессия заканчивается (Switch to Desktop, Return to Gaming Mode),
heartbeat не ждётся, пока агент новой сессии его не пришлёт; пока ВМ приостановлена или спит,
индикатор выключен, а после возобновления, пробуждения гостя и сна Mac отсчёт простоя и heartbeat
начинается заново.

| Клавиши в окне | |
|---|---|
| Ctrl+Cmd+F | полный экран |
| Ctrl+Cmd+G | захватить / отпустить мышь вручную |
| Ctrl+Cmd+P | Metal Performance HUD Apple (FPS, интервал кадров, время GPU, память) вкл/выкл; то же View → Show Metal Performance HUD и Settings > Display |
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
`--mouse tablet` — абсолютный планшет (gamescope его не принимает, так что только для других
композиторов в госте), `--mouse capture` — всегда захват по щелчку.

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
| General | оверлей загрузки/выключения; индикатор «Still working…» при простое GPU; «When FX Steam Launcher is in the background»: **Mute sound** (по умолчанию вкл.: `krun_snd_set_volume(…, mute)` с плавным затуханием ~150 мс, громкость возвращается при возврате в окно) и **Pause the game** (по умолчанию выкл.: агент гостя замораживает только игру в фокусе — `systemctl --user freeze app-steam-app<appid>-*.scope`, cgroup v2; Steam, загрузки и обновления продолжают работать; сетевые игры могут отключиться). Пока агент подтверждает заморозку (`game-frozen`/`game-thawed`), окно затемнено, с карточкой «Game paused · Click to resume» и заголовком «— paused»; щелчок по окну возвращает игру и в гостя не передаётся; отчёты о сбоях (`--no-crash-reports`, см. ниже); **Check for updates at startup** (по умолчанию вкл., см. «Проверка обновлений»); лог статистики кадров (`--perf-stats`) | полный экран при старте; **Use the Mac's time zone** (по умолчанию вкл., см. выше) |
| Display | гость следует за размером окна; Metal Performance HUD Apple в правом верхнем углу окна (Ctrl+Cmd+P, View → Show Metal Performance HUD) | источник физического размера (авто по экрану / DPI / мм — `--dpi`, `--display-mm`), частота (`--refresh`), размер окна (`--display`): стандартные разрешения от 1280 × 800 (Steam Deck) до 3840 × 2160 (не помещающиеся на экран помечены «larger than this screen», окно ужимается как раньше), «Fit to screen» (наибольший размер для экрана, пересчитывается при каждом запуске) или «Custom…» (поля W × H) |
| Mouse | авто-захват в играх; список игр (имя из `appmanifest_<appid>.acf`, Default/Auto/Off, удалить) | — |
| Controller | какой физический контроллер (GameController) ведёт виртуальный pad (первый подключённый или выбранный), получает ли SteamOS pad и каким он виден (`--no-gamepad`, `--pad`, см. «Контроллер»), A/B и X/Y местами, мёртвая зона стиков, живой тест ввода | — |
| Sound | устройство вывода (System default следует за macOS или конкретное CoreAudio-устройство), громкость/mute, буфер Low/Normal/Safe — через `krun_snd_set_*` (ищутся `dlsym`; со старым libkrun поля выключены с пояснением) | звук (`--no-sound`) |
| Advanced | — | vCPU (`--cpus`), RAM (`--mem`), SSH вкл/выкл + порт (`--ssh-port`, `--no-ssh`) и сгенерированный пароль, сеть (`--no-net`), образ диска (`--disk`), Create New Disk…, клиент Steam (`--steam-client`, см. «Клиент Steam»), Vulkan-драйвер (`--vulkan-driver`, см. «Vulkan-драйвер») |

Для тестов: `STEAMAC_DEFAULTS_DOMAIN=<домен>` подменяет домен настроек; `--selftest-settings
--selftest-out DIR` открывает окно без ВМ и пишет PNG каждой вкладки; в `--control-fifo` есть
`settings TAB`, `settings-dump PNG`, `set KEY VALUE` (как из окна), `restart`.

## Приостановка (Suspend)

**Как:** Settings → General → «When closing the window» → **Suspend** — тогда закрытие окна
приостанавливает ВМ вместо выключения; или меню **FX Steam Launcher → Suspend** (Ctrl+Cmd+S,
работает и когда клавиатура у гостя). `krun_pause` (патч libkrun 0016) останавливает все vCPU и
звук гостя, окно прячется, в строке меню появляется значок ⏸: «SteamOS suspended», с какого
времени и сколько памяти занято, **Resume**, **Shut Down SteamOS**. Приостановленная ВМ не тратит
CPU (~0 %), Mac может засыпать.

**Возобновление:** щелчок по иконке в Dock, повторный запуск приложения (Finder, `open`, `open -a`),
значок в строке меню или меню → **Resume**. Окно возвращается (и полноэкранный режим, если был),
захват мыши восстанавливается; плашка «Resuming…» держится до первого нового кадра гостя (если
GPU гостя простаивает, как у неподвижного интерфейса Steam, — 0,5 с; максимум 2,5 с).

**Часы:** монотонные часы гостя паузу не видят (libkrun сдвигает виртуальный таймер, как QEMU) —
планировщик sched_ext и watchdog'и не срабатывают. Настенные часы сразу после возобновления
выставляет `fx-clock-sync.service` (root-сервис слоя, тот же бинарник `fx-progress-agent
clock-sync`, запускается udev при появлении порта): лаунчер пишет своё время `time <unix_ns>` в
virtio-порт `fx.clock`, сервис сдвигает только CLOCK_REALTIME (`clock_adjtime(ADJ_SETOFFSET)`,
только вперёд и только если отстаёт больше чем на 1 с), после шага timesyncd синхронизируется сам.

**Выход:** Cmd+Q / Dock → Quit во время приостановки спрашивает «SteamOS is suspended»:
**Shut Down SteamOS** (гость возобновляется и штатно выключается) или **Cancel** (остаётся
приостановленным). Выход из учётной записи, перезагрузка и выключение Mac не спрашивают.

**Ограничения:** состояние живёт только в памяти, пока работает FX Steam Launcher, — на диск оно
не сохраняется (память гостя и состояние GPU хоста — virglrenderer, MoltenVK, Metal — не
сериализуются). Выход из приложения, его сбой, выход из учётной записи или выключение Mac — это
обычное выключение SteamOS, несохранённый прогресс игры теряется. Вся память гостя остаётся
занятой, пока ВМ приостановлена. Сетевые соединения гостя (онлайн-игры, загрузки) после долгой
паузы могут оборваться и переподключиться.

## Сон SteamOS (Sleep)

Steam → Power → **Sleep**, автосон Steam по простою (Settings → Power → «Sleep after», по
умолчанию 1 час) и `systemctl suspend` в госте не усыпляют ядро гостя (s2idle в ВМ разбудить нечем —
раньше SteamOS так и висел до выхода из приложения). Слой подменяет `ExecStart` у
`systemd-suspend.service` (и `systemd-suspend-then-hibernate` / `systemd-hybrid-sleep` — то же
самое; гибернация выключена в `sleep.conf.d`) на `fx-progress-agent sleep`: он выполняет хуки
`system-sleep` (`pre`), пишет `sleep <action> <token>` в virtio-порт `fx.sleep` и ждёт ответа.
Лаунчер приостанавливает ВМ (`krun_pause`, как Suspend — CPU ~0 %, Mac может засыпать), но окно
остаётся: поверх кадра — карточка «SteamOS is sleeping». Щелчок, клавиша, кнопка геймпада или
иконка в Dock будят: `krun_resume`, гостю уходит `wake <token> <unix_ns>`, команда сдвигает
настенные часы (как clock-sync), выполняет хуки `post` и завершается — logind шлёт
PrepareForSleep(false), Steam просыпается; плашка «Waking up…» держится до первого кадра. Щелчок или
клавиша, разбудившие гостя, в гостя не попадают.

Закрытие окна во время сна — по «When closing the window»: Suspend прячет окно (Resume потом и
будит), Shut Down / Cmd+Q будят гостя и нажимают кнопку питания, когда задача сна в госте закончилась
(`awake <token>`; пока она идёт, logind кнопку игнорирует). Без порта (`--headless`, старый лаунчер)
сон в госте завершается ошибкой, а не засыпанием.

Для тестов в `--control-fifo`: `close`, `suspend`, `resume` (будит и спящего гостя), `reopen`,
`quit`, `wake` (как пробуждение Mac), `quit-prompt shutdown|cancel|dump PNG`,
`status open|close|dump PNG|item TITLE`.

## Режим рабочего стола (Desktop Mode)

Steam → Power → **Switch to Desktop** запускает KDE Plasma; значок **Return to Gaming Mode** на рабочем
столе возвращает обратно. В образе Steam Frame этот режим — VR-стол (`plasma-session.target` хочет
SteamVR, который в ВМ замаскирован), поэтому слой его заменяет: `plasma-session.target` и
`steamac-nested-desktop.service` запускают Plasma одним окном KWin внутри того же gamescope
(`/usr/lib/steamac/nested-desktop`, как `steamos-nested-desktop` Valve) размером с дисплей, так что
gamescope показывает его 1:1. `gamescope-onready` ждёт этот сервис: когда Plasma завершается, сессия
заканчивается и SDDM входит заново. У Plasma свой runtime-каталог и своя сессионная шина D-Bus;
прослойка `steamosctl` из слоя (`/usr/lib/steamac/desktop-bin`, первой в её PATH) отправляет команды
SteamOS, например Return to Gaming Mode, на внешнюю шину, где работает steamos-manager. Автозапуск
Steam на рабочем столе (`/usr/lib/steamac/desktop-xdg/autostart/steam.desktop`) сохраняет клиент,
выбранный в лаунчере, вместо штатного `-deckard` (клиент Frame), из-за которого при каждом
переключении скачивался бы другой клиент. Агент прогресса сообщает `focus desktop <w>x<h>` (окно
Plasma): лаунчер оставляет относительную мышь и переносит её на это окно так, как его масштабирует
gamescope, а загрузка сразу в рабочий стол (`steamos-session-select plasma-persistent`) сообщает
`ready`, когда стол появился.

Flatpak-приложения (Discover) работают в bubblewrap, который монтирует свой procfs в user namespace.
Ядро разрешает это, только пока в пространстве монтирования есть полностью видимый procfs, а initramfs
накрывает настоящий `/proc/cmdline` синтезированным; поэтому он ещё монтирует нетронутый procfs в
`/run/steamac/proc` (`nosuid,nodev,noexec`). Без него каждое Flatpak-приложение завершается с
`bwrap: Can't mount proc on /newroot/proc: Operation not permitted`.

## Буфер обмена (Clipboard)

Settings → General → **Share clipboard with SteamOS** (по умолчанию вкл., применяется сразу): текст
(UTF-8) и PNG-изображения, скопированные на Mac, вставляются в SteamOS (Ctrl+V — в текстовые поля
Steam, в игры и приложения Desktop Mode) и обратно; ограничения — 1 МиБ текста и 16 МиБ на
изображение (больше — пропускается со строкой в логе). Элементы, которые менеджеры паролей помечают
как скрытые или временные (`org.nspasteboard.ConcealedType` / `TransientType`), остаются на Mac, пока
не включено **Include concealed (password manager) items**. Лаунчер проверяет `changeCount`
буфера таймером 0,5 с только пока приложение активно и VM работает, и один раз при каждой активации —
никогда в фоне, при приостановке или сне; изображения из SteamOS попадают на Mac как PNG + TIFF.

Транспорт: virtio-console порт `fx.clipboard`, двоичные кадры (`HELLO` / `STATE` / `SET` с
порядковыми номерами / `ACK`; `host/launcher/Sources/steamac-vm/Clipboard.swift`,
`guest/progress-agent/src/clipboard.rs`). В госте пользовательский сервис
`fx-clipboard-agent.service` (`fx-progress-agent clipboard`, его хотят и игровая сессия, и Desktop
Mode) владеет `CLIPBOARD` и следит за ним (XFixes; TARGETS, UTF8_STRING, text/plain;charset=utf-8,
TEXT, STRING, image/png, INCR больше 256 КиБ) на **обоих** Xwayland-серверах gamescope (`:0` Steam,
`:1` игры): gamescope сам синхронизирует между ними простой текст, перехватывая выделение, но не
изображения и не текст размером под INCR. В Desktop Mode используется ещё Wayland-буфер сессии
Plasma через `zwlr_data_control_manager_v1` (`ext_data_control_manager_v1`, если есть); KWin
передаёт его X11-приложениям, пока активно X11-окно. Подавление эха — по содержимому: каждая
сторона помнит последнее отправленное или принятое содержимое, так что одно копирование — одна
передача, сколько бы раз gamescope, KWin или Klipper его ни переобъявляли. Выделение, уже бывшее на
дисплее при его появлении (например, история, восстановленная Klipper), на Mac не отправляется —
туда предлагается общее содержимое. В `--control-fifo` есть `chord KEYCODE ctrl` (например,
`chord 9 ctrl` = Ctrl+V в госте) и `set shareClipboard on|off`.

## Контроллер

Любой контроллер, который поддерживает GameController в macOS (Xbox, DualSense, DualShock 4, MFi, …),
ведёт один геймпад в SteamOS; какой — выбирается в Settings → Controller. Это не virtio-input
устройство: лаунчер передаёт его по порту virtio-console `fx.pad` root-сервису гостя
`fx-pad.service` (`fx-progress-agent pad`, его запускает udev, когда порт появляется), а тот создаёт
его через uinput. Поэтому он следует за Mac, пока ВМ работает: появляется, когда контроллер
подключается (Steam показывает «Controller Connected»), исчезает вместе с последним и меняет вид
вместе с ним. Settings → Controller → **Appears in SteamOS as** (`--pad auto|xbox360|dualsense|dualshock4`
на один запуск):

- **Automatic** (по умолчанию): того же вида, что и ведущий контроллер — DualSense (или Edge) →
  DualSense, DualShock 4 → DualShock 4, любой другой → контроллер Xbox 360;
- **Xbox 360 controller**: то, что показывает драйвер ядра `xpad` (`045e:028e`);
- **DualSense** / **DualShock 4**: то, что показывают `hid-playstation` / `hid-sony` для USB-pad
  (`054c:0ce6` / `054c:09cc`, версия `0x8111`, кнопки по положению, цифровые L2/R2 рядом с
  аналоговыми курками). SDL в Steam сопоставляет его как контроллер PS5 / PS4 и показывает значки
  PlayStation.

**Вибрация.** У pad есть `FF_RUMBLE`, как у настоящих драйверов, так что SDL и Steam им вибрируют —
игры через Steam Input доходят до него через виртуальный Xbox-pad Steam. Воспроизведение uinput
оставляет драйверу в user space: `fx-pad` повторяет правила ff-memless ядра (задержка, длительность,
повторы, повторная загрузка, сложение эффектов) и отправляет лаунчеру итоговый уровень
`rumble <strong> <weak>`, а тот играет его через haptics GameController: сильный мотор — на левой
рукояти, слабый — на правой (у контроллеров без раздельных рукоятей — один уровень на всё); пока ВМ
приостановлена — ничего. Протокол порта — в `guest/progress-agent/src/pad.rs`. Сенсорная панель,
гироскоп, световая панель и адаптивные курки — HID-функции настоящего контроллера, которых у этого
evdev-устройства нет.

Тестовые команды `--control-fifo`: `pad on` (pad без контроллера, как в `--input-selftest`),
`pad off`, `pad test` (A + левый стик), `pad state` (pad гостя и последний уровень вибрации).

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

Один образ диска одновременно использует только одна ВМ: процесс ВМ держит эксклюзивную блокировку
(`flock`) на записываемом диске до выхода, и второй лаунчер (другая копия приложения, например сборка
из исходников рядом с `/Applications`, или `steamac-vm`) не запускается, а показывает «SteamOS is
already running», вместо того чтобы смонтировать те же файловые системы второй раз (это портит
`/home` и `/var`). Блокировка держится и после убитого лаунчера, пока гость ещё выключается.
Лаунчеры, собранные до блокировки, её не проверяют.

Если в `/home` при загрузке всё же есть ошибки (ВМ убита во время записи или диск открыли два старых
лаунчера без блокировки), SteamOS чинит его, а не останавливается на «Starting SteamOS services…»:
лаунчер добавляет `fsck.repair=yes` в командную строку ядра, и systemd-fsck запускает e2fsck с ответом
«да» на все вопросы, а не только с безопасными исправлениями preen. Файлы, которые e2fsck не смог
вернуть на место, оказываются в `/home/lost+found`.

## Создание диска SteamOS без Docker (Creating the SteamOS disk without Docker)

Пользователю приложения Docker не нужен: диск создаёт сам лаунчер — окно первого запуска
**Create New Disk…** или **Settings → Advanced → Create New Disk…** (ветка stable/rc/beta/preview/main,
размер home, место, пароль пользователя `steamos`; прогресс, Stop и Resume). То же без окна:

```sh
work/out/steamac-vm --create-disk ~/steamos.img [--branch stable] [--home-gib 64] [--password PW] [--keep-cache] [--accept-eula]
```

Ничего не скачивается, пока пользователь не принял условия Valve: «End User License Agreement for
SteamOS and Steam Client Back-Up Image» (тот же текст, что на странице образа Steam Frame,
`https://store.steampowered.com/steamos/download/?ver=steamframe`: только личное использование, без
распространения) и Steam Subscriber Agreement. В окне это флажок со ссылками на оба текста — без
него Create недоступна; в командной строке — `--accept-eula`, без него `--create-disk` печатает
ссылки и завершается с кодом 2. Принятие (дата и URL соглашения) хранится в домене настроек и
действует, пока URL соглашения в коде (`SteamOSLicense.eulaURL`) не изменится.

1. `https://steamdeck-atomupd.steamos.cloud/meta/holo/steamos/aarch64/vr/<ветка>.json` → свежий
   кандидат (`update_path`, `chunks_store_path`).
2. Скачивается `.raucb` (~2 МБ); CMS-подпись проверяется Security.framework только против
   закреплённого CA Valve `CN=steamdeck-images` (`scripts/keys/steamdeck-images.pem`, SHA-256 отпечаток
   зашит в код); системное хранилище доверия не используется. Свой читатель squashfs (zstd из
   закреплённого релиза zstd, `fetch-zstd.sh`) достаёт `manifest.raucm` и `rootfs.img.caibx`;
   проверяются `compatible=steamos-aarch64`, версия и размер слота.
3. Официальный desync (`fetch-desync.sh`, версия и sha256 закреплены) собирает 10-гигабайтный
   `rootfs.img` из хранилищ чанков Valve (~4,4 ГБ данных); кеш чанков — `desync/` в
   `~/Library/Caches/es.fxgam.steamac` для диска на томе домашней папки, иначе в `<диск>.cache`
   рядом с диском (внешнему диску тогда не нужно место на внутреннем; после успеха папка удаляется).
   Частичный `<диск>.rootfs-tmp` тоже остаётся, поэтому Stop/Resume (или повтор команды после
   Ctrl+C) продолжает с места остановки. Одновременно — одно создание на кеш: второе (другое окно или
   `--create-disk`) останавливается с «another SteamOS disk is being created» (`flock` на
   `creation.lock` в папке кеша), а не делит кеш чанков и временные файлы.
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

## Клиент Steam (Steam client)

Какой клиент Steam запускает SteamOS, выбирается в лаунчере: окно первого запуска, окно
**Create SteamOS Disk** и **Settings → Advanced → Steam client** (applies on next start, «Restart VM
to apply»), для одного запуска — `--steam-client frame|deck|deckbeta`. Лаунчер передаёт выбор при
каждой загрузке в cmdline ядра `steamac.steam_client=…`; его читает `/usr/lib/steamac/steam-client`
из слоя при каждом старте Steam. Сервис Steam остаётся стоковым из SteamOS (`steam.service`), слой
добавляет к нему только drop-in `steam.service.d/50-steamac.conf`; `steam-client` перед стартом
копирует стоковый `/usr/share/deckard/RUNSTEAM.sh` в `~/.local/share/Steam/` — без изменений для
клиента Frame с запомненным аккаунтом, а в режимах `deck`/ветки/входа удаляет из копии только строки
аргументов `-deckard` и `-vrgamepadui`. Файлы Valve в слой не входят.

| Вариант | Что это | Плюсы и минусы |
|---|---|---|
| **Steam Deck client** (`deck`, по умолчанию) | публичный ARM64-клиент Steam Deck, ветка `steamdeck_stable` (та же сборка, что публичный `steam_client_linuxarm64`; официально для ARM не объявлен) | обычный вход с QR-кодом на экране; публичная ветка клиента, а не внутренняя бета |
| **Steam Deck client (beta)** (`deckbeta`) | ветка `steamdeck_publicbeta` | как `deck`, но бета |
| **Steam Frame client** (`frame`) | бета-клиент Valve для Steam Frame (`linux_arm64_beta_<hash>`, флаги `-deckard -vrgamepadui`) — как в образе | клиент, который идёт в образе; внутренняя бета ещё не вышедшего устройства; вход — через режим входа (ниже) |

Смена варианта при следующем старте Steam скачивает другой клиент (до ~1 ГБ, прогресс в оверлее
загрузки); обратно на Frame загрузчик Steam переключается сам по флагу `-deckard`. Ручной
`/etc/steamac/steam-client-branch` внутри SteamOS (любая ветка клиента) по-прежнему работает, когда
выбран `frame` (или лаунчер не передаёт параметр — старые версии, свой `--cmdline`); выбор `deck` /
`deckbeta` в лаунчере важнее файла.

## Vulkan-драйвер (Vulkan driver)

Vulkan-драйвер хоста за Venus выбирается в **Settings → Advanced → Vulkan driver** (при следующем
запуске) или на один запуск флагом `--vulkan-driver moltenvk|kosmickrisp`. virglrenderer открывает
драйвер во время работы (без Vulkan-загрузчика): перед стартом ВМ лаунчер ставит `VKR_VULKAN_DRIVER`
в `@rpath/libMoltenVK.dylib` или `@rpath/libvulkan_kosmickrisp.dylib`. Оверлей загрузки показывает
драйвер («Venus → KosmicKrisp»); в отчётах о сбоях есть `vulkan_driver` и ревизия патчей драйвера.

| Вариант | Что это | Плюсы и минусы |
|---|---|---|
| **MoltenVK** (`moltenvk`, по умолчанию) | `host/moltenvk/`: форк UTM + патчи steamac | любой поддерживаемый Mac; игры проверены с ним; проверки устройства D3D12 (vkd3d-proton) проходят |
| **KosmicKrisp** (`kosmickrisp`, экспериментально) | `host/kosmickrisp/`: Mesa main + открытые MR (геометрические шейдеры !44786, transform feedback !44928, tiled-изображения в host-pointer памяти !44929, device-local тип памяти !44221, линейные цели рендера !44782/!44222) + патчи steamac (явный row pitch LINEAR, LINEAR как input attachment, `fillModeNonSolid`, без которого DXVK не запускается, 8 сэмплов как 4, выравнивание texel-буферов по одному текселю и пулы таймстампов на нескольких счётчиковых кучах Metal, нужные vkd3d-proton) | только macOS 26+ (Metal 4); собирается, только если сборка идёт на macOS 26+, иначе настройка откатывается на MoltenVK. Интерфейс Steam, DXVK-игры и Stellar Blade Demo (D3D12, vkd3d-proton) работают; первый запуск Stellar Blade — ~28 мин компиляции шейдеров на M1 Max; известный пробел (repro на хосте): transform feedback со strip-геометрическими шейдерами и его счётчик при переполнении (черновой MR) |

Смена драйвера меняет идентичность драйвера Venus (UUID кэша конвейеров): Steam и игры заново
собирают кэши шейдеров. Конвейер, который драйвер хоста не смог собрать, остаётся заглушкой в
virglrenderer: его draw и dispatch отбрасываются, `VK_NULL_HANDLE` до драйвера не доходит.

Проверки без ВМ: `host/kosmickrisp/build.sh` гоняет `host/moltenvk/probe` и repro
(`REPRO_DRIVER=kosmickrisp host/moltenvk/repro/run.sh <dylib>`, через Khronos-загрузчик, только для
тестов) на собранном драйвере; `host/virglrenderer/build.sh` гоняет `venus_check` с каждым
установленным драйвером.

## Вход в Steam (Signing in)

Экран входа клиента Steam Frame рассчитан на шлем: «Tap to confirm» связывается с телефоном по
Bluetooth LE, «Scan QR code» открывает VR-окно — в ВМ оба не работают (остаётся только пароль).
Поэтому с клиентом Steam Frame, пока в `config/loginusers.vdf` нет запомненного аккаунта (новый
диск, выход из аккаунта, вход без «Remember me»), `steam-client` запускает Steam без `-deckard`/`-vrgamepadui`: загрузчик сам
переключается на публичный ARM64-клиент Steam Deck (`steamdeck_stable`), и вход показывает
QR-код на экране (Steam Mobile App → Steam Guard → сканировать) рядом с формой пароля. После входа
с «Remember me» Steam один раз перезапускается и возвращается к клиенту Steam Frame (каждая смена
клиента — загрузка до ~1 ГБ, прогресс виден в оверлее загрузки). Без доступа к
`client-update.steamstatic.com` режим входа не включается.

Строки `RecvMsgClientLogOnResponse() : 'Try another CM'` в `connection_log.txt` на экране входа —
норма: сервер CM разрывает соединение без входа в аккаунт через ~60 с, клиент переподключается.

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

Лицензии: `bundle.sh` кладёт в `Contents/Resources/licenses` все тексты лицензий сторонних
компонентов бандла и индекс `THIRD-PARTY-NOTICES.txt` (компонент, версия, SPDX, где лежит в бандле,
исходники; собирает `host/launcher/licenses.sh` в `work/out/licenses`, в том числе крейты libkrun и
модули Go из gvproxy/desync), плюс `LICENSE` и `NOTICE` проекта в `licenses/steamac/`. `dist.sh`
вызывает `scripts/gpl-sources.sh` и рядом с DMG кладёт
`work/out/dist/FX-Steam-Launcher-<версия>-gpl-sources.tar` — полный исходный код GPL-компонентов
(ядро с патчами и конфигом, busybox из Debian-снапшота, dosfstools, e2fsprogs, btrfs-progs, скрипты
сборки, `README.txt`); его прикладывают к релизу на GitHub вместе с DMG. Для старого релиза:
`scripts/gpl-sources.sh v1.2`.

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
  пайплайнов MoltenVK (`[mvk-error] … compile failed`; если MoltenVK напечатал исходник MSL
  (`[mvk-msl] …`: первые 40 строк и строки вокруг ошибки) — он уходит в extra `msl_source`, не в
  breadcrumbs; строка vkr «pipeline … creation failed on host» — только breadcrumb),
  паника Rust в libkrun (`thread … panicked at`), провал первичной настройки диска (`provision
  failed`), провал создания диска, неожиданный выход ВМ (ненулевой код или сигнал, если выключение не
  запрошено пользователем), «SteamOS is not responding» индикатора простоя;
- выход ВМ по SIGTERM/SIGINT/SIGHUP (выход из системы, `kill`, ^C до установки обработчиков) — не
  падение: только строка в логе, без события и без окна Report a Problem. SIGPIPE — тоже (оба
  процесса его игнорируют: закрытый канал вывода — терминал или канал stderr супервизора после того,
  как супервизор убит, — только даёт ошибку записи; процесс ВМ тогда пишет лог в
  `~/Library/Logs/es.fxgam.steamac/steamac-vm.log` или отбрасывает строки и даёт гостю довыключиться;
  STEAMAC-10). SIGKILL — событие
  `vm-killed` уровня warning «VM process killed (SIGKILL — memory pressure or force quit)»: убило ли
  ядро за память (jetsam, `NOTE_EXIT_DETAIL` из kqueue супервизора), память ВМ и footprint процесса ВМ
  при выходе/пик, `vm_stat`-числа хоста (free/compressed/wired, swap), `kern.memorystatus_level` и
  история уровней memory pressure с начала загрузки (переходы пишутся и в лог: `memory pressure: …`).
  Force Quit из меню приложения — запрошенный выход, не отчёт;
- в каждом событии — последние ~200 строк stderr лаунчера как breadcrumbs (строки `[steamac-vm]`,
  `[mvk-*]`, предупреждения libkrun/virglrenderer, этапы загрузки) и теги: версия
  (`es.fxgam.steamac@<CFBundleShortVersionString>+<git sha>`), окружение и тег `build_kind`:
  `release` — только сборка `dist.sh` с нотаризацией (Info.plist `SteamacDistTeamID`, и подпись
  работающего кода — Developer ID этой команды, проверка `SecCodeCheckValidity`), `source-build` —
  любой другой `.app` (`bundle.sh`, ad-hoc/переподписанные копии, `dist.sh --no-notarize`),
  `development` — `work/out/steamac-vm` вне бандла; macOS, модель Mac, GPU, vCPU/RAM, режим дисплея,
  UUID сборок libkrun / virglrenderer / MoltenVK, `MVK_PATCH_REVISION`, версия ядра, BUILD_ID SteamOS
  и релиз слоя (из строк initramfs), `appid` игры в фокусе гостя (пока она в фокусе), случайный ID
  установки.

Не отправляется: консоль гостя (hvc0), имя пользователя и компьютера (`/Users/<имя>` → `~`, имя и
hostname вырезаются), IP (`sendDefaultPii=false`, сервер не выводит IP), локаль/часовой пояс,
аккаунт Steam, названия игр (только App ID), файлы. Супервизор пропускает свой stderr через канал
(всё по-прежнему попадает в терминал/лог), поэтому видит и последние строки упавшего процесса ВМ.

Проверка: `--sentry-test-event` (тестовое событие из супервизора и процесса ВМ, процесс ВМ заодно
отправляет отложенный отчёт о падении и выходит), `--sentry-test-crash abort|segv|metal|panic|kill|term|shader`
(процесс ВМ падает: `abort()` внутри вызова C, `EXC_BAD_ACCESS` в `memset`, assert Metal, паника
Rust в `krun_start_enter` из-за слишком длинной командной строки ядра — для `panic` нужны `--kernel`
и, при необходимости, `--initrd`; `kill`/`term` — процесс ВМ убивает себя SIGKILL (отчёт
`vm-killed`) или SIGTERM (без отчёта и окна); `shader` — печатает пример ошибки компиляции MoltenVK с
`[mvk-msl]` и строку vkr и выходит). Такие события идут с `environment=development` и тегом `test=true`.
`STEAMAC_SENTRY_DEBUG=1` печатает отладочный лог SDK (ответы сервера).

Символы: `build.sh` кладёт dSYM `steamac-vm` и библиотек бандла в `work/out/dSYMs` (libkrun,
virglrenderer и MoltenVK собраны без DWARF — там только таблицы символов). `dist.sh` загружает их и
бинарники приложения через `sentry-cli --url https://sentry.fxgam.es debug-files upload`, если заданы
`SENTRY_AUTH_TOKEN`, `SENTRY_ORG` и `SENTRY_PROJECT`; иначе пишет, что загрузка пропущена.

## Проверка обновлений

При запуске приложения (один раз за запуск, не при каждой перезагрузке ВМ, и не чаще раза в 6 часов —
даже между запусками) лаунчер в фоне, не задерживая загрузку, запрашивает последний релиз
`https://api.github.com/repos/fxgl/steamac/releases/latest` (без авторизации, таймаут 10 с; черновики
и пре-релизы не учитываются) и сравнивает тег `vX.Y[.Z]` со своей версией (`CFBundleShortVersionString`,
численно: 1.3.10 > 1.3.9). Если вышла новая версия, рядом с окном ВМ (не поверх него, если на экране
есть место; без фокуса — клавиатура и захваченная мышь остаются у ВМ) появляется окно «FX Steam
Launcher X.Y is available — you have …» с описанием релиза и кнопками **Download** (открывает в
браузере `.dmg` релиза, иначе страницу релиза), **Skip This Version** (эта версия больше не
предлагается при запуске) и **Remind Me Later** (снова — при следующей проверке). В меню приложения
пункт **Check for Updates…** (пока найденная версия не пропущена — «Update Available: X.Y…» с
отметкой New, открывает это окно) проверяет сразу — без 6-часового ограничения и
пропущенных версий — и сообщает «You're up to date» или ошибку; ошибки сети и HTTP при запуске только
пишутся в лог (`update: …`). Выключается галочкой **Check for updates at startup** в Settings →
General (сразу). Dev-лаунчер `work/out/steamac-vm` при запуске не проверяет (меню работает); сборки
из исходников (`bundle.sh`) и релизы — проверяют.

Приватность: запрос уходит только на `api.github.com` (GitHub) и содержит только `User-Agent:
FXSteamLauncher/<версия>` (плюс стандартные заголовки HTTP и ETag прошлого ответа, чтобы GitHub мог
ответить «не изменилось»); никаких идентификаторов Mac или пользователя, cookies и Sentry. Время
проверки, ETag, ответ и пропущенная версия хранятся в настройках (`updateLastCheck`, `updateETag`,
`updateCachedBody`, `updateCachedURL`, `updateSkippedVersion`).

Тесты: `STEAMAC_UPDATE_URL` подменяет адрес (JSON релиза или массив `/releases`, `http(s)://` или
`file://`; заодно включает проверку при запуске dev-лаунчера), `STEAMAC_FAKE_VERSION` — версию
лаунчера; FIFO `--control-fifo`: `update check|startup|state`, `update press
download|skip|later|ok|releases`, `update dump PNG` (окно и `-with-vm.png` — вместе с окном ВМ, как на
экране).

## Сообщить о проблеме (Report a Problem)

Если что-то не работает, отправьте отчёт разработчикам прямо из лаунчера: **Help → Report a Problem…**
(или в меню приложения), кнопка **Report a Problem…** в Settings → General, ссылка **Report…** на
карточке «SteamOS is not responding…» и кнопка **Report…** в окне «FX Steam Launcher stopped
unexpectedly», которое появляется после неожиданного завершения ВМ (падение, ошибка). В диалоге:
email (обязателен, запоминается на этом Mac — чтобы разработчики могли ответить), описание (что
делали, чего ждали, что произошло) и галочки, что приложить:

- **Include launcher logs** (включено) — сообщения лаунчера, libkrun, virglrenderer и MoltenVK за эту
  сессию (последние ~2 МБ, оба процесса) и строки `perf:`/`stall:`; пути `/Users/<имя>` → `~`, имя
  пользователя и компьютера, email и IP вырезаются;
- **Include SteamOS logs (system journal, Steam/Proton logs)** (включено) — консоль гостя (hvc0) за
  сессию и архив `steamos-logs.tar.gz`, который собирает гостевой агент: журнал systemd текущей загрузки
  (`journalctl -b`, последние 5000 строк, плюс пользовательский журнал), `coredumpctl list`/`info`,
  `dmesg`, `systemctl --failed`, `os-release`, `layer-release`, `/proc/cmdline`, `df`/`free`, хвосты
  логов клиента Steam (`console_log`, `stderr`, `bootstrap_log`, `compat_log`, `connection_log`,
  `webhelper`, `cef_log`, `shader_log`, `steamui_*`) и Proton (`~/steam-*.log` от `PROTON_LOG=1`, `version` и
  `config_info` префиксов в `compatdata`). Steam ID (`[U:1:…]`, 7656119…), имена аккаунтов и
  персон Steam (из `loginusers.vdf`/`registry.vdf`) и email заменяются заглушками до упаковки;
  `collect-notes.txt` в архиве перечисляет, что удалось прочитать;
- **Include a screenshot of the VM window** (выключено по умолчанию: на картинке может быть имя
  аккаунта Steam и друзья).

Всегда прикладываются `system-info.txt` (версии приложения и macOS, модель Mac, GPU, UUID сборок
libkrun/virglrenderer/MoltenVK, ядро, BUILD_ID SteamOS, релиз слоя, размеры диска, параметры ВМ,
заметки о сборе) и `settings.txt` (сохранённые настройки и переопределения из командной строки;
пароль SSH лежит в связке ключей и никогда не попадает в отчёт, названия игр — тоже).
**Show What Will Be Sent** собирает отчёт и открывает его папку в Finder — отправляется ровно её
содержимое.

Отчёт уходит как User Feedback в Sentry (`sentry.fxgam.es`, тот же проект): email, описание, связь с
последним событием об ошибке этой сессии (если было) и файлы как вложения, одним конвертом напрямую
на envelope-endpoint — так виден ответ сервера. Работает и при выключенных отчётах о сбоях (явное
действие пользователя: SDK и обработчик падений при этом не запускаются). Вложения ограничены 20 МБ
(сначала обрезаются старые части логов, потом выбрасываются скриншот и архив SteamOS); на ответ
HTTP 413 лимит уменьшается вдвое и отчёт отправляется снова. После отправки показывается короткий
Report ID (первые 8 знаков ID события). Не удалось отправить — папка остаётся в
`~/Library/Logs/es.fxgam.steamac/reports/<дата>-<ID>/` (`report.json` с email и описанием плюс
файлы); в диалоге **Retry** и **Reveal in Finder**, папку можно прислать почтой.

Как это устроено: супервизор всегда пропускает stderr обоих процессов через канал и пишет его в
`/tmp/steamac-<pid>/launcher.log` (с временем, ротация по 4 МБ), процесс ВМ пишет консоль hvc0 в
`console.log` рядом; каталог удаляется при выходе лаунчера. Гостевые логи запрашиваются по тому же
порту `fx.progress` в обратную сторону: лаунчер пишет `collect-logs <id>`, агент (от пользователя
сессии, только то, что тому доступно) отвечает `logs-begin <id> <размер>`, строками
`logs <id> <base64>` и `logs-end <id> <sha256>` (или `logs-failed <id> <причина>`), лаунчер собирает
архив и проверяет размер и SHA-256. Нет ответа за 20 с или агент не работает (нет heartbeat) —
отчёт уходит без гостевых логов, с пометкой в `system-info.txt`.

Проверка: `--control-fifo PATH`, команды `report open`, `report fill EMAIL ТЕКСТ…` (событие с тегом
`test=true`), `report include launcher|steamos|screenshot on|off`, `report preview`, `report send`,
`report retry`, `report dsn DSN|default`, `report dump PNG`, `report close`; `STEAMAC_REPORT_DSN`
подменяет DSN (путь отказа), `STEAMAC_SENTRY_DEBUG=1` печатает ответ сервера. Окно после падения:
`--sentry-test-crash abort` с `STEAMAC_REPORT_DUMP=<каталог>` (PNG окна и диалога, затем закрывается
само; `STEAMAC_REPORT_TEST_SEND=1` — заодно отправить тестовый отчёт).

## Как это устроено

| Каталог | Что внутри |
|---|---|
| `host/moltenvk/` | MoltenVK utmapp `geometry-shaders` @05604465 + патчи: depth_clip_enable, YCbCr-массивы, null-дескрипторы, эмуляция геометрических шейдеров для zink/DXVK (шаг вершин, instancing, adjacency, fans, SCALED-форматы, `gl_in`), transform feedback (stream output DXVK) и его запросы (статистика SO), доступность результатов запросов при копировании (occlusion-запросы DXVK через Venus), атомики на компонентах векторов по адресам буферов (BDA, vkd3d-proton), texel-буферы со смещением на любой тексель (vkd3d-proton), запись в маленькие буферы push-дескрипторов с robustness2, массивы дескрипторов переменной длины как runtime-массивы (Metal держал 32 МБ на массив кучи vkd3d-proton и программу), распределение служебных буферов, отложенное освобождение Metal-ресурсов, хеш патчей в UUID кэша конвейеров; тесты в `repro/` гоняются под валидацией Metal (и на KosmicKrisp: `REPRO_DRIVER=kosmickrisp`); `bench/run.sh <libdir>…` сравнивает производительность изменений между сборками; `bench/shaders.sh <дамп или пак>` меряет компиляцию шейдеров игры (SPIR-V → MSL, MSL → библиотека Metal, pipeline state; холодный/тёплый кэш, потоки) по дампу шейдеров MoltenVK или 10%-выборке из `bench/pack.py` |
| `host/kosmickrisp/` | KosmicKrisp (Mesa main @ce576c29) + открытые MR Mesa и патчи steamac (см. «Vulkan-драйвер»), без LLVM во время работы (`-Dllvm=disabled`, `mesa_clc` из первой сборки), `-Db_ndebug=true`; только macOS 26+ |
| `host/virglrenderer/` | virglrenderer UTM `macos-next` + слияние с upstream main (venus-protocol 1.1.3) + LINEAR-модификатор, импорт shm как host memory, заглушки для неудавшихся конвейеров (draw отбрасываются в virglrenderer), пересоздание отвергнутого кэша, отложенный unmap shm, QoS потоков, Vulkan-драйвер открывается во время работы (`VKR_VULKAN_DRIVER`) |
| `host/libkrun/` | libkrun v1.19.6 + патчи: `VIRTIO_GPU_F_BLOB_ALIGNMENT` (16K), маска SME для M4, 2D-ресурсы без virgl, `SET_SCANOUT_BLOB`, маппинг SHM-блобов, сигнализация Venus-фенсов, логи virglrenderer, `krun_display_resize` (смена разрешения на лету), QoS vCPU/GPU-потоков |
| `host/launcher/` | `steamac-vm` (Swift/AppKit): окно на Metal, оверлей «FX STEAM LAUNCHER» с прогрессом загрузки/выключения, разрешение гостя = размер окна при постоянном DPI (EDID из физического размера экрана), клавиатура/мышь/планшет, pad гостя Xbox 360 / DualSense / DualShock 4 из GameController.framework с вибрацией (`fx.pad`), сеть через gvproxy, перезапуск ВМ при reboot гостя, `--perf-stats` |
| `guest/kernel/` | Linux 7.2.9, всё встроено, 4K-страницы, выравнивание blob-узлов по 16K, Apple TSO для FEX |
| `guest/mesa/` | Venus ICD для aarch64 (Proton, gamescope, zink) и x86_64/i386 (FEX-провайдер графики) |
| `guest/initramfs/` | загрузочный этап = «загрузчик»: выбор слота A/B со счётчиком попыток, partsets, оверлеи `/etc` и `/usr`; первичная подготовка диска, созданного лаунчером (`steamac.provision=1`: статические mkfs.fat, mke2fs, btrfstune в initramfs); `steamac.ssh=0` — без SSH-сервера; config-payload лаунчера (`steamac.config=1`) — новый пароль `steamos`; `steamac.tz=` — часовой пояс Mac в `/etc/localtime`; нетронутый procfs в `/run/steamac/proc` для песочниц Flatpak |
| `guest/layer/` | слой для ВМ поверх `/usr` (read-only erofs): файловый `splctl`, безопасный post-install для RAUC, `VARIANT_ID=steamdeck`, сессия gamescope на DRM, режим рабочего стола (Plasma внутри gamescope), маски сервисов железа Frame, агент прогресса `fx-progress-agent` (Rust, `guest/progress-agent/`, порт virtio-console `fx.progress`) и его root-сервисы (`fx.clock`, `fx.sleep`, uinput-геймпад на `fx.pad`), быстрые таймауты выключения, режим входа в Steam с QR-кодом (клиент Steam Deck, пока нет запомненного аккаунта), опциональная ветка клиента Steam (`/etc/steamac/steam-client-branch`), фоновая обработка шейдеров Steam включена по умолчанию (`steam-shader-defaults`) |
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
- клавиатура, планшет, мышь и виртуальный pad видны в SteamOS; как DualSense SDL в Steam сопоставляет
  его как `PS5 Controller` (тип PS5) и показывает значки PlayStation; pad появляется, исчезает и
  меняет вид, пока ВМ работает; вибрация из SDL и из виртуального pad Steam доходит до лаунчера
  (`rumble 49152 16384` 1,5 с, затем 0); воспроизведение на физическом контроллере ещё не проверено;
- режим рабочего стола: Switch to Desktop, рабочий стол Plasma с мышью (в том числе с полями), Return
  to Gaming Mode, загрузка сразу в рабочий стол; песочницы Flatpak запускаются;
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

- DirectX 12 (vkd3d-proton): feature level 11_0, SM 6.0 (без tiled-ресурсов, SM 6.2+ на Apple GPU нет). Stellar
  Blade Demo (UE4) идёт в 1280×800, 60 FPS на M4 Max; первый запуск несколько минут компилирует шейдеры.
  x86-эмулятор Proton ARM64 (FEX) один раз уронил её через 20 минут (проверка DEP в защищённом .exe).
- Звук: virtio-snd → CoreAudio (устройство по умолчанию или выбранное в настройках), задержка ≈65 мс на встроенных
  динамиках; микрофон заявлен, но не проверен.
- Античиты, которые блокируют ВМ, не пройдут.
- `logicOp` недоступен (приватный Metal API в форке MoltenVK не собирается); zink выдаёт предупреждение.

## Лицензия (License)

Код проекта — Apache License 2.0 (`LICENSE`), © 2026 FX GAMES FZ LLC. Исключения перечислены в
`NOTICE`: патчи и конфигурация ядра Linux — GPL-2.0-only, патчи для virglrenderer и Mesa — MIT
(как у этих проектов), пять файлов сессии gamescope, производные от пакета Valve
`deckard-steamvr-session`, — MIT © Valve Corporation; сертификат CA Valve и скриншоты в `docs/media`
лицензией проекта не покрываются. Тексты лицензий — в `LICENSES/`.

SteamOS в проект не входит и с ним не распространяется: приложение скачивает подписанный образ
с серверов Valve после того, как пользователь принял лицензию Valve (см. «Создание диска SteamOS
без Docker»).

Steam, логотип Steam, SteamOS, Steam Deck и Steam Frame — товарные знаки и/или зарегистрированные
товарные знаки Valve Corporation в США и/или других странах. Проект не связан с Valve Corporation и
не одобрен ею.
