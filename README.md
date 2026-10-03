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
- Xcode (полный), Homebrew, rustup.
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

| Клавиши в окне | |
|---|---|
| Ctrl+Cmd+F | полный экран |
| Ctrl+Cmd+G | захватить курсор (Ctrl+Option — отпустить) |
| закрыть окно | выключение гостя (кнопка питания) |

Доступ в гостя: `ssh -p 2222 steamos@127.0.0.1`, пароль `steamos` (меняется через
`STEAMOS_PASSWORD=... scripts/build-image.sh disk`). Консоль hvc0 — в терминале, где запущен `run.sh`.

## Как это устроено

| Каталог | Что внутри |
|---|---|
| `host/moltenvk/` | MoltenVK utmapp `geometry-shaders` @05604465 + патчи: depth_clip_enable, YCbCr-массивы и null-дескрипторы (нужны gamescope) |
| `host/virglrenderer/` | virglrenderer UTM `macos-next` + слияние с upstream main (venus-protocol 1.1.3) + исправления эмуляции LINEAR-модификатора |
| `host/libkrun/` | libkrun v1.19.6 + патчи: `VIRTIO_GPU_F_BLOB_ALIGNMENT` (16K), маска SME для M4, 2D-ресурсы без virgl, `SET_SCANOUT_BLOB`, маппинг SHM-блобов, сигнализация Venus-фенсов, логи virglrenderer |
| `host/launcher/` | `steamac-vm` (Swift/AppKit): окно на Metal, клавиатура/мышь/планшет, виртуальный Xbox 360 pad из GameController.framework, сеть через gvproxy |
| `guest/kernel/` | Linux 7.2.9, всё встроено, 4K-страницы, выравнивание blob-узлов по 16K, Apple TSO для FEX |
| `guest/mesa/` | Venus ICD для aarch64 (Proton, gamescope, zink) и x86_64/i386 (FEX-провайдер графики) |
| `guest/initramfs/` | загрузочный этап = «загрузчик»: выбор слота A/B со счётчиком попыток, partsets, оверлеи `/etc` и `/usr` |
| `guest/layer/` | слой для ВМ поверх `/usr` (read-only erofs): файловый `splctl`, безопасный post-install для RAUC, `VARIANT_ID=steamdeck`, сессия gamescope на DRM, маски сервисов железа Frame |
| `scripts/` | сборка `work/out/steamos.img`: GPT в разметке Valve (esp, efi-A/B, rootfs-A/B, var-A/B, home) |

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
- разрешение гостя следует за размером окна при постоянном DPI; быстрое выключение (2–4 с).

Известно: часть compute-шейдеров DXVK пока не компилируется в MSL (zero-init workgroup memory,
`gl_WorkGroupSize`) — такие конвейеры заменяются заглушками, игра не падает, но эффекты могут
отсутствовать.

## Ограничения

- DirectX 12 (vkd3d-proton) не работает: MoltenVK не даёт нужных возможностей.
- Звука нет: virtio-snd в libkrun 1.19.6 требует PipeWire на хосте (только Linux).
- Античиты, которые блокируют ВМ, не пройдут.
- `logicOp` недоступен (приватный Metal API в форке MoltenVK не собирается); zink выдаёт предупреждение.
