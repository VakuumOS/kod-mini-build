# kod-mini-build — сборщик Vakuum OS Builder

**Vakuum OS** — минималистичная операционная система на базе ядра Linux,
собранная «из вакуума»: без GNU-тулчейна там, где без него можно обойтись,
на **musl libc** и **LLVM/Clang + LLD**, из исходников, на целевой машине.

**kod-mini** (Vakuum OS Builder) — это крошечная Live-система, с которой
всё начинается. Она загружается с ISO целиком в оперативную память,
поднимает сеть, размечает целевой диск, скачивает исходники и собирает
на нём основную Vakuum OS. Это «семя», из которого вырастает система.

> **Этап 1 (текущий, MVP):** рабочий терминал в VirtualBox — загрузка в
> RAM, сеть (DHCP + DNS), UTF-8-консоль с кириллицей и переключением
> раскладки EN/RU, инструменты разметки и форматирования дисков,
> автоматический swap при нехватке памяти.
>
> **Этап 2:** статический тулчейн LLVM/Clang + LLD и Rust для musl из
> `kod-mini-toolchain` и интерактивное меню сборки.

```
Welcome to Vakuum OS Builder (kod-mini v0.1 | musl + LLVM)
```

---

## Экосистема: три репозитория

```
                        github.com/VakuumOS
 ┌──────────────────────────────────────────────────────────────────────┐
 │                                                                      │
 │  ┌───────────────────────┐   git clone (main)   ┌──────────────────┐ │
 │  │    kod-mini-build     │ ───────────────────▶ │  kod-mini-rootfs │ │
 │  │  (этот репозиторий)   │   если пуст или      │  /init, сеть,    │ │
 │  │                       │   недоступен ──┐     │  шрифты, keymap, │ │
 │  │  scripts/fetch.sh     │                │     │  меню сборки     │ │
 │  │  scripts/build.sh     │ ◀──────────────┘     └──────────────────┘ │
 │  │  configs/kernel-*     │   fallback-rootfs/                        │
 │  │  configs/limine.conf  │   (встроенная копия)                      │
 │  │  GitHub Actions       │                      ┌──────────────────┐ │
 │  │                       │  KOD_TOOLCHAIN_URL   │kod-mini-toolchain│ │
 │  │                       │ ───────────────────▶ │ LLVM/Clang+LLD,  │ │
 │  └──────────┬────────────┘  (этап 2, опц.)      │ Rust (musl,      │ │
 │             │                                   │ static) — этап 2 │ │
 │             ▼                                   └──────────────────┘ │
 │  out/vakuum-builder-x86_64.iso  (BIOS + UEFI, Limine)                │
 └──────────────────────────────────────────────────────────────────────┘
```

| Репозиторий | Роль |
|---|---|
| **kod-mini-build** | Скачивание исходников, сборка ядра и userspace, упаковка ISO, CI |
| **kod-mini-rootfs** | Оверлей корневой ФС: `/init`, сетевые хуки, шрифты Terminus (UTF-8, кириллица), раскладка, меню сборки |
| **kod-mini-toolchain** | Этап 2: статический LLVM/Clang + LLD и Rust для musl (подключается переменной `KOD_TOOLCHAIN_URL`) |

**Fallback.** `scripts/fetch.sh` клонирует
`https://github.com/VakuumOS/kod-mini-rootfs.git`. Если репозиторий
недоступен или пуст (нет коммитов или нет файлов кроме README), то `/init`
и конфигурация берутся из каталога [`fallback-rootfs/`](fallback-rootfs/).
Поэтому ISO собирается уже с первого коммита этого репозитория. Если
kod-mini-rootfs содержит файлы, они накладываются **поверх**
fallback-rootfs (поддерживается и подкаталог `rootfs/`).

---

## Архитектура образа

```
 Limine (BIOS / UEFI, гибридный ISO)
   │  vmlinuz + rootfs.img + initramfs.img   (Limine склеивает модули)
   ▼
 Ядро Linux 6.12 LTS (make LLVM=1, без модулей, всё нужное — built-in)
   ▼
 stage 1: initramfs (статический BusyBox + stage1/init)
   │  rootfs.sfs (SquashFS, zstd) ─ уже в RAM  ─ или ─ loop с носителя
   │  OverlayFS: lower = SquashFS, upper = tmpfs в RAM
   ▼  switch_root
 /init (PID 1, fallback-rootfs или kod-mini-rootfs)
   │  /proc /sys /dev /dev/pts /run /tmp, UTF-8 консоль, шрифт, раскладка
   │  eth0/enp* + udhcpc (NAT, DNS), auto-swap, баннер
   ▼
 setsid cttyhack bash  — на tty1 (и ttyS0, если есть последовательный порт)
```

* **Загрузчик:** Limine (ветка `v8.x-binary`), гибридный ISO для BIOS и
  UEFI (x86_64 + IA32 UEFI), собирается `xorriso` + `limine bios-install`.
* **Корневая ФС:** SquashFS (zstd, блок 1 MiB) + OverlayFS в RAM. Образ
  влезает в память машины с **512 МБ** RAM. Пункт меню «low memory» не
  копирует SquashFS в RAM, а монтирует его прямо с носителя.
* **Тулчейн:** musl + LLVM/Clang + LLD. Ядро собирается через
  `make LLVM=1`, userspace — обёрткой `kod-cc` (`clang --target=*-linux-musl
  -fuse-ld=lld -static` с sysroot на musl).
* **Userspace:** статические BusyBox и GNU Bash 5.3 (со всеми патчами),
  util-linux (`sfdisk`, `fdisk`, `lsblk`, `wipefs`, `blkid`), e2fsprogs
  (`mkfs.ext4`, `e2fsck`, `tune2fs`, `resize2fs`), dosfstools (`mkfs.fat`,
  `fsck.fat`).
* **Локализация консоли:** EN + RU, UTF-8, кириллический шрифт Terminus
  (или `cyr-sun16` из kbd) через `setfont`, раскладка `ru` с
  переключением **Ctrl+Shift**.
* **Архитектуры:** x86_64; aarch64 подготовлен (`configs/kernel-aarch64.config`,
  `--arch aarch64`, UEFI-only).

### Ядро

`defconfig` архитектуры + фрагменты, объединённые
`scripts/kconfig/merge_config.sh`, затем `olddefconfig`. После этого
`build.sh` **проверяет, что каждая строка фрагментов попала в итоговый
`.config`**, и останавливает сборку, если опция потерялась из-за
неудовлетворённых зависимостей.

| Файл | Содержимое |
|---|---|
| `configs/kernel-common.config` | initramfs, SquashFS+zstd, OverlayFS, loop, devtmpfs, SATA/AHCI, NVMe, virtio, ext4, btrfs, vfat, iso9660, NLS UTF-8/CP866/CP1251/KOI8-R, DRM + fbcon, сеть, ZRAM |
| `configs/kernel-x86_64.config` | ATA_PIIX, EFI stub, FB_EFI/VESA, DRM_VBOXVIDEO, VMware/Bochs, E1000, PCnet32, VBOXGUEST, 8250 serial |
| `configs/kernel-aarch64.config` | PL011 serial, ARM-специфичные драйверы |

### Auto-swap

Сборка основной системы требует памяти. `vakuum-prep-swap` (вызывается
из `/init` при загрузке и вручную) при RAM < 4 ГБ:

1. включает **zram** (сжатый swap в RAM, приоритет 100);
2. если на целевом диске уже есть раздел с меткой `VAKUUM_ROOT`, создаёт
   на нём **временный swap-файл** `/.vakuum-swapfile` (приоритет 10,
   для btrfs с `chattr +C`).

```sh
vakuum-prep-swap /dev/sda2      # swap-файл на разделе / смонтированной ФС
vakuum-prep-swap --status
vakuum-prep-swap --off          # выключить и удалить временный swap
```

Пороги задаются в `/etc/kod/swap.conf`, отключить — параметром ядра
`kod.noswap`.

---

## Сборка

### В GitHub Actions (рекомендуется)

Workflow [`.github/workflows/build.yml`](.github/workflows/build.yml)
запускается при push в `main` и вручную (**Actions → build → Run
workflow**). Каталог `sources/` кэшируется (`actions/cache@v4`), готовый
ISO публикуется как артефакт `vakuum-builder-x86_64-<sha>`.

### Локально (Ubuntu 24.04 / Debian 13)

```sh
sudo apt install clang lld llvm libclang-rt-18-dev musl-tools xorriso mtools \
    bc bison flex libelf-dev libssl-dev cpio zstd squashfs-tools curl xz-utils \
    bzip2 kbd make perl python3 git

scripts/fetch.sh                 # исходники -> sources/, оверлей -> work/
scripts/build.sh                 # ARCH=x86_64 по умолчанию
# => out/vakuum-builder-x86_64.iso (+ .sha256)
```

Полезные варианты:

```sh
scripts/fetch.sh --resolve       # показать итоговые версии и выйти
scripts/build.sh kernel-config   # только сконфигурировать и проверить ядро
scripts/build.sh rootfs initramfs iso   # пересобрать отдельные стадии
scripts/build.sh --arch aarch64  # подготовлено (экспериментально)
scripts/build.sh --clean -v      # чистая сборка с выводом логов
```

Логи стадий: `work/<arch>/logs/*.log`. Стадии, входные данные которых не
изменились, пропускаются.

Версии зафиксированы в [`configs/versions.conf`](configs/versions.conf);
любую можно переопределить переменной окружения, например
`KERNEL_VERSION=6.12.100 scripts/fetch.sh`. По умолчанию берётся самый
свежий выпуск ядра 6.12.x с kernel.org.

**Этап 2:** чтобы встроить тулчейн из kod-mini-toolchain, задайте URL
архива (`@ARCH@` заменяется на архитектуру). Он распакуется в
`/opt/kod-toolchain` и попадёт в `PATH`:

```sh
KOD_TOOLCHAIN_URL=https://github.com/VakuumOS/kod-mini-toolchain/releases/download/v1/kod-toolchain-@ARCH@.tar.zst \
    scripts/fetch.sh && scripts/build.sh
```

### Структура репозитория

```
configs/
  versions.conf            версии и URL исходников
  kernel-common.config     фрагменты ядра (общий + по архитектурам)
  kernel-x86_64.config
  kernel-aarch64.config
  busybox.config           фрагмент BusyBox (поверх defconfig)
  limine.conf.in           шаблон меню загрузчика
scripts/
  fetch.sh                 скачивание исходников + выбор оверлея rootfs
  build.sh                 сборка тулчейна, ядра, userspace, ISO
  lib/common.sh            общие функции
stage1/init                init initramfs: SquashFS + OverlayFS -> switch_root
fallback-rootfs/           встроенный оверлей rootfs (/init, /etc, утилиты)
.github/workflows/build.yml
```

---

## Запуск в VirtualBox

1. **Создать ВМ:** *Машина → Создать*.
   * Тип: **Linux**, версия: **Other Linux (64-bit)** (Linux 64-bit).
   * Память: **2048 МБ** (минимум 512 МБ).
   * Жёсткий диск: новый VDI, **20 ГБ** или больше — сюда будет
     собираться Vakuum OS.
2. **Система → Материнская плата:**
   * Порядок загрузки: *Оптический диск* выше *Жёсткого диска*.
   * **Включить EFI** — для загрузки через UEFI. Если флажок снят, ВМ
     загрузится через BIOS. ISO гибридный, работают **оба режима**.
3. **Система → Процессор:** 2+ ядра (сборка идёт быстрее).
4. **Носители:**
   * Контроллер: **SATA (AHCI)**. Подключите к нему диск и оптический
     привод с `vakuum-builder-x86_64.iso`.
5. **Сеть → Адаптер 1:**
   * Тип подключения: **NAT**.
   * *Дополнительно → Тип адаптера:* **Intel PRO/1000 MT Desktop
     (82540EM)** — драйвер `e1000` встроен в ядро.
6. **Дисплей:** графический контроллер **VMSVGA** (или VBoxVGA), 16+ МБ
   видеопамяти.
7. *(Опционально)* **Последовательные порты → Порт 1:** включить, режим
   «Raw File» или «Host Pipe» — получите второй shell на `ttyS0`, удобно
   для логов.
8. **Запустить.** В меню Limine выберите *Vakuum OS Builder* (по
   умолчанию через 5 секунд).

После загрузки появится баннер и приглашение bash. Проверка:

```sh
ip addr                 # адрес от DHCP NAT VirtualBox (10.0.2.15)
ping -c3 github.com     # сеть и DNS
lsblk                   # целевой диск: /dev/sda
echo 'Привет, Vakuum!'  # UTF-8 и кириллица
kod_help                # подсказка по командам
```

Пример подготовки диска (**уничтожает данные на /dev/sda**):

```sh
wipefs -a /dev/sda
printf 'label: gpt\nsize=512M, type=uefi\ntype=linux\n' | sfdisk /dev/sda
mkfs.fat -F32 -n VAKUUM_EFI /dev/sda1
mkfs.ext4 -L VAKUUM_ROOT /dev/sda2
vakuum-prep-swap /dev/sda2
```

### Пункты меню загрузчика

| Пункт | Назначение |
|---|---|
| Vakuum OS Builder | rootfs целиком в RAM (по умолчанию) |
| low memory | SquashFS читается с носителя (`kod.media`) |
| safe graphics | `nomodeset` — если экран остаётся чёрным |
| serial console | основная консоль — последовательный порт |
| Rescue shell | shell BusyBox в initramfs до монтирования rootfs |

### Параметры ядра

| Параметр | Действие |
|---|---|
| `kod.media` | не грузить rootfs в RAM, монтировать SquashFS с носителя |
| `kod.toram` | вместе с `kod.media`: скопировать SquashFS в RAM |
| `kod.ramsize=N%` | размер tmpfs для записываемого слоя (по умолчанию 75%) |
| `kod.timeout=N` | сколько секунд ждать загрузочный носитель |
| `kod.break[=premount\|mount]` | остановиться в shell stage 1 |
| `kod.nonet` | не настраивать сеть |
| `kod.iface=IF` | использовать указанный сетевой интерфейс |
| `kod.noswap` | не включать auto-swap |
| `kod.shell=PATH` | другой shell вместо bash |
| `kod.debug` | подробный вывод init |

### Консоль

```sh
vakuum-console ru        # раскладка US + RU, переключение Ctrl+Shift
vakuum-console us        # только латиница
vakuum-console font ter-u32n.psf   # крупный шрифт (HiDPI)
vakuum-console status
```

---

## Лицензии компонентов

Собираемые компоненты распространяются под собственными лицензиями:
Linux, BusyBox, util-linux, e2fsprogs, dosfstools, kbd — GPL-2.0;
GNU Bash — GPL-3.0+; musl — MIT; Limine — BSD-2-Clause;
шрифт Terminus — OFL-1.1.
