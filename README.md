🎯 ЧТО У НАС ЕСТЬ - ОБЗОР СИСТЕМЫ
🎬 МЕДИА-ЦЕНТР (ГЛАВНАЯ ФУНКЦИЯ)
text
🎬 JELLYFIN + АВТОПОИСК = ДОМАШНИЙ NETFLIX
Поиск фильмов → вводишь название → через 30 сек смотришь

Автозагрузка обложек, описания, субтитров

Буферизация как в YouTube - не ждешь полной загрузки

Автоочистка - просмотренные фильмы удаляются сами

Как использовать:

Открываешь Jellyfin (телевизор/телефон/компьютер)

Видишь кнопку "🔍 Поиск фильмов"

Вводишь "Интерстеллар" → жмешь "Смотреть"

Через 30 секунд фильм начинает играть!

🔒 СОБСТВЕННЫЙ VPN ДЛЯ ОБХОДА БЛОКИРОВОК
text
🌐 ВАШ ЛИЧНЫЙ VPN СЕРВЕР
Для Hiddify - обход блокировок YouTube, ChatGPT, Netflix

Случайные порты - меняются каждые 24 часа для анонимности

Ваш IP - все трафик идет через ваш домашний сервер

Что можно делать:

Смотреть зарубежный Netflix из России

Использовать ChatGPT, Grok без ограничений

Смотреть заблокированный YouTube контент

Анонимный серфинг в интернете

☁️ ФАЙЛОВОЕ ХРАНИЛИЩЕ
text
📁 NEXTCLOUD = ВАШЕ ОБЛАКО
Синхронизация файлов между устройствами

Общие папки для семьи/друзей

Резервные копии фото и документов

Доступ из интернета к вашим файлам

🤖 ЛОКАЛЬНЫЙ ИСКУССТВЕННЫЙ ИНТЕЛЛЕКТ
text
🧠 OLLAMA = ВАШ CHATGPT ДОМА
Полная приватность - все запросы локально

Работает без интернета

Бесплатно - никаких подписок

Понимает русский

🔐 МЕНЕДЖЕР ПАРОЛЕЙ
text
🗝️ VAULTWARDEN = ВАШ 1PASSWORD
Безопасное хранение паролей

Автозаполнение в браузерах

Синхронизация между устройствами

Self-hosted - ваши данные только у вас

🚀 РЕАЛЬНЫЕ СЦЕНАРИИ ИСПОЛЬЗОВАНИЯ
🏠 ДЛЯ СЕМЬИ:
text
Вечер кино: 
1. Муж ищет "Мстители" в Jellyfin → через 30 сек смотрят
2. Дети смотрят мультики с телефона/планшета  
3. Жена заливает фото в Nextcloud с телефона
4. Все защищены VPN при серфинге
💼 ДЛЯ РАБОТЫ:
text
Удаленная работа:
1. Доступ к рабочим файлам через Nextcloud
2. Консультации с AI-ассистентом без ограничений
3. Безопасный VPN для доступа к корпоративным ресурсам
4. Хранение паролей от рабочих сервисов
🎮 ДЛЯ РАЗВЛЕЧЕНИЙ:
text
Медиа-центр:
1. Торренты качаются напрямую в систему
2. Фильмы появляются в Jellyfin автоматически
3. Субтитры на русском подгружаются сами
4. Можно смотреть с любого устройства дома
🌐 ДЛЯ ПУТЕШЕСТВИЙ:
text
Доступ из любой точки мира:
1. Подключаешься к домашнему VPN
2. Смотришь свои фильмы как дома
3. Доступ к файлам как будто ты дома
4. Все твои сервисы доступны безопасно
🔧 ТЕХНИЧЕСКИЕ ВОЗМОЖНОСТИ
📊 МОНИТОРИНГ:
Uptime Kuma - следит за всеми сервисами

Уведомления если что-то упало

Статистика использования

🔄 АВТОМАТИЗАЦИЯ:
Radarr/Sonarr - автоматический поиск контента

Bazarr - автоматические субтитры

qBittorrent - умная загрузка торрентов

🔐 БЕЗОПАСНОСТЬ:
Единый вход - один пароль для всей системы

Fail2ban - защита от взлома

Автообновления - система всегда актуальна

Резервные копии - настройки не потеряются

💡 ЧЕМ ЭТО ЛУЧШЕ КОММЕРЧЕСКИХ РЕШЕНИЙ?
Функция	Коммерческий аналог	Наше решение
🎬 Видео	Netflix ($15/мес)	Бесплатно
☁️ Файлы	Google Drive ($2/мес)	Бесплатно
🧠 AI	ChatGPT Plus ($20/мес)	Бесплатно
🔐 Пароли	1Password ($5/мес)	Бесплатно
🌐 VPN	ExpressVPN ($13/мес)	Бесплатно
ИТОГО	~$55/мес	БЕСПЛАТНО
🎯 ПРОСТОЙ СПОСОБ НАЧАТЬ:
Открой браузер → введи http://[IP-адрес]:8088

Войди (логин: admin, пароль: homeserver)

Нажми на Jellyfin в панели управления

Наслаждайся поиском и просмотром фильмов!

🔄 ЧТО ДЕЛАТЬ ДАЛЬШЕ:
Настрой VPN на телефоне (файл в /home/$USER/vpn/hiddify-client.conf)

Установи Nextcloud на телефон для синхронизации фото

Добавь закладки в менеджер паролей

Поэкспериментируй с AI-ассистентом

По сути - у тебя теперь свой личный Google/Apple/Microsoft, но полностью под твоим контролем, бесплатно и без ограничений! 🚀

Что нужно заменить:
# Меняем основные настройки (найди в начале скрипта):
DOMAIN="твой-домен"                    # Твой DuckDNS домен
TOKEN="твой-token"                     # Твой DuckDNS токен
USERNAME=$(whoami)                     # Имя пользователя
SERVER_IP=$(hostname -I | awk '{print $1}') # IP сервера




Как запустить? Все просто!
ssh username@ip_сервера "cd /tmp && git clone https://github.com/levgh/serverins.git && cd serverins/main && chmod +x install-server.sh && sudo ./install-server.sh"
📥 АЛЬТЕРНАТИВНЫЕ СПОСОБЫ
curl -sSL https://raw.githubusercontent.com/levgh/serverins/main/install-server.sh | sudo bash
Время устоновки 20-∞ Завист от вашего сервера интернет соеденение


📱 ДАННЫЕ ДЛЯ ВХОДА (ПО УМОЛЧАНИЮ)(Заменить!)
Логин: admin
Пароль: homeserver


✅ ЧТО УЖЕ НАСТРОЕНО АВТОМАТИЧЕСКИ:
Единая система входа:

Главная страница (порт 8088):
Логин: admin
Пароль: homeserver
Автоматически созданные сервисы:
🐳 Все Docker контейнеры запущены

🌐 Домен DuckDNS настроен

🔧 Базовые настройки применены

🔧 ЧТО НУЖНО НАСТРОИТЬ ВРУЧНУЮ:
1. 🎬 JELLYFIN (Первая настройка)
После установки зайди:
http://ip_сервера:8096
Шаги настройки:
Выбери язык → Русский
Создай пользователя:
Имя пользователя: admin (или свое)
Пароль: homeserver (или смени)
Библиотеки - уже настроены автоматически
Настройка завершена - жми "Готово"

2. ☁️ NEXTCLOUD (Настройка БД)
Зайди: http://ip_сервера/nextcloud
Заполни форму:
Логин: admin
Пароль: homeserver (рекомендую сменить)
Папка данных: /var/www/html/nextcloud/data
Настройки БД:
- MySQL/MariaDB
- Пользователь БД: nextclouduser  
- Пароль БД: homeserver
- Имя БД: nextcloud
- Хост: localhost

3. 🔐 VAULTWARDEN (Менеджер паролей)
Зайди: http://ip_сервера:8000


Нажми "Create account":
- Email: admin@localhost (или твой email)
- Пароль: homeserver (ОБЯЗАТЕЛЬНО СМЕНИ!)

4. 📊 UPTIME KUMA (Мониторинг)
Зайди: http://ip_сервера:3001
Первая настройка:
- Придумай пароль администратора
- Настрой уведомления (опционально)
5. 🔍 OVERSEERR (Поиск фильмов)
Зайди: http://ip_сервера:5055
Настрой подключение к Jellyfin:


URL: http://jellyfin:8096
Логин: admin
Пароль: homeserver

🎯 ПОШАГОВАЯ ИНСТРУКЦИЯ ПОСЛЕ УСТАНОВКИ:
ШАГ 1: Главный вход
# Открой в браузере:
http://ip_твоего_сервера:8088
# Войди с:
Логин: admin
Пароль: homeserver
ШАГ 2: Настройка сервисов по порядку:
1. Jellyfin → Создай пользователя
2. Nextcloud → Настрой базу данных
3. Vaultwarden → Создай аккаунт
4. Overseerr → Подключи Jellyfin
5. Uptime Kuma → Настрой пароль
ШАГ 3: Настройка автоматических загрузок
В Radarr (http://ip_сервера:7878):
Настрой индексеры (Jackett)
Настрой пути загрузки
Настрой качество видео
В Sonarr (http://ip_сервера:8989):
Аналогично Radarr для сериалов




🎯 WHAT WE HAVE - SYSTEM OVERVIEW

🎬 MEDIA CENTER (MAIN FUNCTION)
🎬 JELLYFIN + AUTO-SEARCH = YOUR PERSONAL NETFLIX
Find movies → enter title → start watching in 30 seconds

Automatic download of covers, descriptions, subtitles

YouTube-like buffering - no waiting for full downloads

Auto-cleanup - watched movies are deleted automatically

How to use:

Open Jellyfin (TV/phone/computer)

Click the "🔍 Search Movies" button

Type "Interstellar" → click "Watch"

The movie starts playing in 30 seconds!

🔒 PERSONAL VPN FOR BYPASSING BLOCKS
🌐 YOUR OWN VPN SERVER

For Hiddify - bypass blocks on YouTube, ChatGPT, Netflix

Random ports - change every 24 hours for anonymity

Your IP - all traffic goes through your home server

What you can do:

Watch international Netflix from Russia

Use ChatGPT, Grok without restrictions

Watch blocked YouTube content

Anonymous internet browsing

☁️ FILE STORAGE
📁 NEXTCLOUD = YOUR PERSONAL CLOUD

File synchronization between devices

Shared folders for family/friends

Photo and document backups

Access your files from anywhere online

🤖 LOCAL ARTIFICIAL INTELLIGENCE
🧠 OLLAMA = YOUR HOME ChatGPT

Complete privacy - all requests processed locally

Works without internet

Free - no subscriptions

Understands Russian

🔐 PASSWORD MANAGER
🗝️ VAULTWARDEN = YOUR 1PASSWORD

Secure password storage

Auto-fill in browsers

Sync between devices

Self-hosted - your data stays with you

🚀 REAL USE CASE SCENARIOS
🏠 FOR FAMILY:
Movie night:

Husband searches "Avengers" in Jellyfin → watches in 30 seconds

Kids watch cartoons on phone/tablet

Wife uploads photos to Nextcloud from phone

Everyone protected by VPN while browsing

💼 FOR WORK:
Remote work:

Access work files through Nextcloud

Consult AI assistant without limits

Secure VPN for corporate resources

Store passwords for work services

🎮 FOR ENTERTAINMENT:
Media center:

Torrents download directly to system

Movies appear in Jellyfin automatically

Russian subtitles load automatically

Watch from any device at home

🌐 FOR TRAVEL:
Access from anywhere:

Connect to home VPN

Watch your movies like at home

Access files as if you were home

All your services available securely

🔧 TECHNICAL CAPABILITIES
📊 MONITORING:

Uptime Kuma - monitors all services

Notifications if something goes down

Usage statistics

🔄 AUTOMATION:

Radarr/Sonarr - automatic content search

Bazarr - automatic subtitles

qBittorrent - smart torrent downloading

🔐 SECURITY:

Single sign-on - one password for entire system

Fail2ban - protection against hacking

Auto-updates - system always current

Backups - settings won't be lost

💡 WHY THIS IS BETTER THAN COMMERCIAL SOLUTIONS?

Feature	Commercial Alternative	Our Solution
🎬 Video	Netflix ($15/month)	FREE
☁️ Files	Google Drive ($2/month)	FREE
🧠 AI	ChatGPT Plus ($20/month)	FREE
🔐 Passwords	1Password ($5/month)	FREE
🌐 VPN	ExpressVPN ($13/month)	FREE
TOTAL	~$55/month	FREE
🎯 EASY WAY TO START:
Open browser → enter http://[IP-address]:8088

Login (username: admin, password: homeserver)

Click Jellyfin in control panel

Enjoy searching and watching movies!

🔄 WHAT TO DO NEXT:

Set up VPN on phone (file in /home/$USER/vpn/hiddify-client.conf)

Install Nextcloud on phone for photo sync

Add bookmarks to password manager

Experiment with AI assistant

Essentially - you now have your personal Google/Apple/Microsoft, but completely under your control, free and without limitations! 🚀

What needs to be replaced:

bash
# Change main settings (find at beginning of script):
DOMAIN="your-domain"                    # Your DuckDNS domain
TOKEN="your-token"                      # Your DuckDNS token
USERNAME=$(whoami)                      # Username
SERVER_IP=$(hostname -I | awk '{print $1}') # Server IP
How to run? It's simple!

bash
ssh username@server_ip "cd /tmp && git clone https://github.com/levgh/serverins.git && cd serverins/main && chmod +x install-server.sh && sudo ./install-server.sh"
📥 ALTERNATIVE METHODS

bash
curl -sSL https://raw.githubusercontent.com/levgh/serverins/main/install-server.sh | sudo bash
Installation time: 20-∞ minutes (Depends on your server internet connection)

📱 DEFAULT LOGIN CREDENTIALS (Change these!)

Username: admin

Password: homeserver

✅ WHAT'S ALREADY SET UP AUTOMATICALLY:
Unified login system:

Main page (port 8088):

Username: admin

Password: homeserver

Automatically created services:

🐳 All Docker containers running

🌐 DuckDNS domain configured

🔧 Basic settings applied

🔧 WHAT NEEDS MANUAL CONFIGURATION:

🎬 JELLYFIN (First setup)
Access: http://server_ip:8096
Setup steps:

Select language → Russian

Create user:

Username: admin (or your own)

Password: homeserver (or change it)

Libraries - already configured automatically

Setup complete - click "Done"

☁️ NEXTCLOUD (Database setup)
Access: http://server_ip/nextcloud
Fill out form:

Username: admin

Password: homeserver (recommend changing)

Data folder: /var/www/html/nextcloud/data
Database settings:

MySQL/MariaDB

Database user: nextclouduser

Database password: homeserver

Database name: nextcloud

Host: localhost

🔐 VAULTWARDEN (Password Manager)
Access: http://server_ip:8000
Click "Create account":

Email: admin@localhost (or your email)

Password: homeserver (MUST CHANGE!)

📊 UPTIME KUMA (Monitoring)
Access: http://server_ip:3001
First setup:

Create admin password

Configure notifications (optional)

🔍 OVERSEERR (Movie Search)
Access: http://server_ip:5055
Configure Jellyfin connection:

URL: http://jellyfin:8096

Username: admin

Password: homeserver

🎯 STEP-BY-STEP POST-INSTALLATION GUIDE:

STEP 1: Main Login

bash
# Open in browser:
http://your_server_ip:8088
# Login with:
Username: admin
Password: homeserver
STEP 2: Configure services in order:

Jellyfin → Create user

Nextcloud → Setup database

Vaultwarden → Create account

Overseerr → Connect Jellyfin

Uptime Kuma → Setup password

STEP 3: Setup automatic downloads

In Radarr (http://server_ip:7878):

Configure indexers (Jackett)

Configure download paths

Configure video quality

In Sonarr (http://server_ip:8989):

Same as Radarr but for TV shows
