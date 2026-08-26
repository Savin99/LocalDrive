# LocalDrive

Личное хранилище важных файлов для iPhone. Всё лежит только на устройстве: без облака, аккаунтов и сети.

## Что умеет

- **Папки** со своим именем, цветом и иконкой (16 иконок, 8 цветов). На карточке папки — коллаж из превью её последних файлов
- **Сводка хранилища** на главном: сколько занято, кольцевая диаграмма по папкам в их цветах, лента недавно добавленного
- **Тёмная тема** — переключается вместе с системной настройкой телефона
- **Цвет папки как тема экрана**: внутри папки её оттенок подхватывают фон и кнопки
- **Два вида отображения** файлов — карточками и списком, выбор запоминается
- **Настоящие превью**: фото показывается фотографией, PDF и документы — первой страницей, текстовые файлы — первыми строками. Для форматов без превью — иконка по типу
- **Добавление** документов из «Файлов» и фото/видео из галереи (до 20 за раз)
- **Просмотр** любого файла системным QuickLook, «Поделиться» через стандартный лист
- **Переименование, удаление** (с подтверждением), **поиск** по имени внутри папки
- **Защита**: Face ID со запасным 4-значным кодом, автоблокировка при уходе в фон, шторка приватности в переключателе приложений
- **Анимации**: разворот карточки папки в экран (zoom-переход), пружинное появление карточек, живой градиент и раскрывающийся замок на входе

Минимальная версия — iOS 18: zoom-переход между карточкой и экраном папки появился только в ней.

## Как это защищено

- Код не хранится нигде в открытом виде: в Keychain лежит только соль и SHA-256 от «соль + код»
- Файлы лежат в `Application Support/Vault/<UUID папки>/` с `FileProtectionType.complete` — на заблокированном устройстве они зашифрованы и недоступны даже самой системе
- Keychain-запись помечена `WhenUnlockedThisDeviceOnly` — не уезжает в iCloud и в бэкапы

Ограничение, о котором стоит знать: 4-значный код перебирается быстро, если у кого-то есть доступ к разблокированному устройству. Настоящая защита данных здесь — шифрование файловой системы iOS, привязанное к паскоду телефона.

## Установка на свой iPhone

Проект генерируется из `project.yml` через [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```bash
xcodegen generate
```

Дальше:

1. Открыть `LocalDrive.xcodeproj` в Xcode
2. Подключить iPhone кабелем и выбрать его как устройство сборки
3. Нажать ⌘R

Подпись — автоматическая, но Team ID в репозитории не лежит. Выберите свою команду в Xcode: таргет **LocalDrive → Signing & Capabilities → Team**. Чтобы не выбирать её заново после каждого `xcodegen generate`, положите ID один раз в `Support/Signing.local.xcconfig` (этот файл в `.gitignore`):

```
DEVELOPMENT_TEAM = ABCDE12345
```

Если Xcode попросит, разрешите доступ к Keychain и на самом iPhone подтвердите доверие профилю разработчика: **Настройки → Основные → VPN и управление устройством**.

При сборке через Apple ID без платного аккаунта разработчика приложение живёт на устройстве 7 дней, потом нужно пересобрать.

## Сборка .ipa для подписи своим сертификатом

```bash
xcodebuild -project LocalDrive.xcodeproj -scheme LocalDrive -configuration Release \
  -sdk iphoneos -derivedDataPath build/ipa \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" CODE_SIGN_ENTITLEMENTS="" build

mkdir -p build/Payload build/dist
cp -R build/ipa/Build/Products/Release-iphoneos/LocalDrive.app build/Payload/
rm -rf build/Payload/LocalDrive.app/_CodeSignature
(cd build && zip -qry dist/LocalDrive-1.0-unsigned.ipa Payload && rm -rf Payload)
```

Готовый файл — `build/dist/LocalDrive-1.0-unsigned.ipa`: unsigned, Release, arm64, bundle id `com.ilyaqa.LocalDrive`.

Подписывающий инструмент должен сохранить в Info.plist оба описания доступа — `NSFaceIDUsageDescription` и `NSPhotoLibraryUsageDescription`, иначе Face ID и выбор фото будут падать при первом обращении.

Если после переподписи Keychain окажется без нужного entitlement, `PinStore` сам переключится на файл `pin.dat` в контейнере приложения с `FileProtectionType.complete` — код всё равно сохранится между запусками.

## Иконка

Текущая иконка — абстрактный куб из слоёв на тёмном индиго, вариант `v7` из [Design/icon-variants/](Design/icon-variants/). Там же лежат все 13 сгенерированных вариантов и общий лист `_all.png`.

Иконки сгенерированы через Higgsfield CLI, моделью `recraft_v4_1`:

```bash
higgsfield generate create recraft_v4_1 --prompt "<описание>" \
  --aspect-ratio 1:1 --resolution 1k --model-type standard --wait
```

Модель рисует скруглённый квадрат со светлыми уголками, а iOS маскирует иконку сам — поэтому перед установкой картинку надо прогнать через [Design/finalize_icon.py](Design/finalize_icon.py), он растягивает внутреннюю часть на весь квадрат и проверяет, что светлых уголков не осталось:

```bash
python3 Design/finalize_icon.py Design/icon-variants/v7.png \
  Sources/Assets.xcassets/AppIcon.appiconset/icon-1024.png
```

Чтобы поставить другой вариант — подставьте его номер в команду выше и пересоберите.

## Структура кода

```
Sources/
  LocalDriveApp.swift          вход, автоблокировка по scenePhase
  Theme.swift                  палитра, стиль карточек, русские склонения
  Models/VaultStore.swift      папки (метаданные в JSON) и файлы (читаются с диска)
  Security/Keychain.swift      обёртка над Keychain
  Security/LockManager.swift   Face ID, проверка и смена кода
  Views/
    RootView.swift             блокировка / первый запуск / главный экран
    Lock/                      PIN-пад, экран входа, создание и смена кода
    Home/                      сетка папок, карточка, редактор папки
    Folder/                    список и сетка файлов, миниатюры, просмотр
    Shared/EmptyStateView.swift
```

Метаданные папок — в `Vault/vault.json`; сами файлы никуда не индексируются, список всегда читается прямо из файловой системы.
