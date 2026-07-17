# Плагин Seva.ru для Lyrion Music Server (LMS)

Плагин добавляет поддержку проигрывания эфира **Радио Сева** и записей архивов программ «Рок-посевы» и «Севаоборот» Севы Новгородцева непосредственно в Lyrion Music Server (ранее Logitech Media Server).

**Только для истинных ценителей.**

## Возможности

1. **Радио Сева**:
   - Воспроизведение круглосуточного аудиопотока в реальном времени (`https://seva.ru/radio/stream`).

2. **Рок-посевы**:
   - Просмотр архива программ по годам (с 1977 по 2009 год).
   - Выбор выпусков из каталога и проигрывание MP3 записей.

3. **Севаоборот**:
   - Просмотр архива программ по годам (с 1987 по 2019 год).
   - Поддерживает отображение даты, темы программы, имен приглашенных гостей и проигрывание записей.

## Установка (ручная)

1. Скопируйте папку `Seva` в директорию плагинов вашего сервера LMS (обычно это папка `Plugins` внутри рабочей директории сервера).
2. Убедитесь, что папка переименована в `Seva` (структура: `Plugins/Seva/Plugin.pm`, `Plugins/Seva/install.xml` и т.д.).
3. Перезапустите Lyrion Music Server.
4. Плагин должен появиться в разделе плагинов и в меню «Мои приложения».

## Установка (из репозитория)

Добавьте в "Настройки→Подключаемые модули→Дополнительные репозитории" адрес https://chernyshalexander.github.io/Seva/dev.xml.

## Лицензия
MIT

---

# Seva.ru Plugin for Lyrion Music Server (LMS)

This plugin adds support for playing the **Radio Seva** live stream and archived recordings of Seva Novgorodtsev’s legendary programs *Rock Poseyvy* and *Sevaoborot* directly in Lyrion Music Server (formerly Logitech Media Server).

**Only for true connoisseurs.**

## Features

1. **Radio Seva**:
   - Live 24/7 audio stream (`https://seva.ru/radio/stream`).

2. **Rock Poseyvy**:
   - Browse the archive by year (1977–2009).
   - Select and play MP3 recordings of the episodes.

3. **Sevaoborot**:
   - Browse the archive by year (1987–2019).
   - Displays date, episode topic, guests, and allows playback of recordings.

## Installation (Manual)

1. Copy the `Seva` folder into your LMS Plugins directory (usually `Plugins` inside the server’s working directory).
2. Make sure the folder is named exactly Seva (structure: Plugins/Seva/Plugin.pm, Plugins/Seva/install.xml, etc.).
3. Restart Lyrion Music Server.
4. The plugin should appear in the Plugins section and in the My Apps menu.

## Installation (from Repository)

Add the following URL in *Settings → Plugins → Additional Repositories*:

https://chernyshalexander.github.io/Seva/dev.xml

## License
MIT
