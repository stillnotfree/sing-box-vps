# sing-box-vps

[![CI](https://github.com/stillnotfree/sing-box-vps/actions/workflows/ci.yml/badge.svg)](https://github.com/stillnotfree/sing-box-vps/actions/workflows/ci.yml)
[![Последний релиз](https://img.shields.io/github/v/release/stillnotfree/sing-box-vps?display_name=tag&sort=semver)](https://github.com/stillnotfree/sing-box-vps/releases/latest)
[![Лицензия](https://img.shields.io/github/license/stillnotfree/sing-box-vps)](LICENSE)

[English](README.md) · **Русский**

Минималистичный интерактивный установщик личного сервера sing-box на чистом
VPS. Сервер просто устанавливается, безопасно обновляется и управляется из
терминала без веб-панели.

## Возможности

- Устанавливает последнюю стабильную версию sing-box из официального подписанного репозитория.
- Поднимает VLESS + REALITY + Vision на TCP/443 и Hysteria2 + TLS на UDP/443.
- Не использует веб-панель, Docker, статистику, телеметрию и журналы подключений.

## Что потребуется

- Debian 13, Ubuntu 24.04 LTS или Ubuntu 26.04 LTS на `amd64`;
- от 1 vCPU, 1 ГБ оперативной памяти и 10 ГБ диска;
- публичный IPv4 и полноценный запуск через systemd;
- домен или поддомен с прямой `A`-записью на адрес VPS;
- настоящий адрес электронной почты для Let's Encrypt;
- **публичный** ключ OpenSSH одной строкой, например `ssh-ed25519 ...`;
- проверенный REALITY target с TLS 1.3 и HTTP/2.

Никогда не передавайте и не загружайте приватный SSH-ключ.

Откройте в firewall или security group провайдера:

| Протокол | Порт | Назначение |
| --- | ---: | --- |
| TCP | Текущий порт SSH | Администрирование |
| TCP | 80 | Проверка Let's Encrypt |
| TCP | 443 | VLESS + REALITY |
| UDP | 443 | Hysteria2 |
| TCP | 8443 | Приватные подписки |

DNS-запись должна вести прямо на VPS. Не включайте для неё CDN или DNS proxy и
не создавайте `AAAA`, если IPv6 не настроен намеренно.

## Установка

Подключитесь к VPS как `root` и выполните:

```bash
wget -qO vpn-install.sh https://raw.githubusercontent.com/stillnotfree/sing-box-vps/v1.0.5/install-sing-box-server.sh && chmod 700 vpn-install.sh && ./vpn-install.sh install
```

Установщик запросит администратора, публичный SSH-ключ, IPv4 сервера, домен,
почту, текущий SSH-порт, REALITY target, страну VPS и fingerprint клиента.
Перед изменениями он покажет полный план и попросит ввести `YES`. Прерванную
установку обычно можно продолжить той же командой.

## Первый вход

Не закрывайте установочную SSH-сессию. В другом окне терминала войдите под
созданным администратором:

```bash
ssh ADMIN_USER@SERVER_IP
```

Первый успешный вход автоматически подтвердит firewall и включит SSH только по
ключу. Дополнительная команда завершения обычно не требуется.

Первый независимый клиент называется `default`. Показать его подписку, ссылки и
QR-коды:

```bash
sudo vpn show default
```

Не публикуйте этот вывод: ссылки содержат данные доступа клиента.

## Команды

| Действие | Команда |
| --- | --- |
| Состояние сервера | `sudo vpn status` |
| Безопасная для публикации диагностика | `sudo vpn diagnostic` |
| Проверка совместимости | `sudo vpn check` |
| Список клиентов | `sudo vpn list` |
| Ссылки и QR-коды клиента | `sudo vpn show NAME` |
| Добавить независимого клиента | `sudo vpn add NAME` |
| Отозвать клиента | `sudo vpn delete NAME --yes` |
| Безопасно обновить sing-box | `sudo vpn update` |
| Сменить REALITY target | `sudo vpn set-target DOMAIN` |
| Выбрать fingerprint | `sudo vpn set-fingerprint` |
| Нативный Hysteria2/QUIC | `sudo vpn set-obfs off` |
| Включить Salamander | `sudo vpn set-obfs salamander` |
| Встроенная справка | `sudo vpn help` |

Изменения target, fingerprint, обфускации, клиентов и sing-box проверяются и
применяются транзакционно. Адреса подписок не меняются, но после изменения
параметров подключения подписку на устройствах нужно обновить.

## Обновления системы

Обычные обновления ОС поддерживаются:

```bash
sudo apt update
sudo apt upgrade
sudo vpn update
sudo vpn status
```

Обновления безопасности ОС устанавливаются автоматически без автоматической
перезагрузки. sing-box обновляется отдельно командой `vpn update`: конфигурация
проверяется, а при неудачном запуске может быть восстановлен предыдущий пакет.

## Что настраивает установщик

| Компонент | Настройка |
| --- | --- |
| Ядро | Стабильный sing-box из подписанного репозитория SagerNet |
| Основной протокол | VLESS + REALITY + Vision на TCP/443 |
| Резерв | Hysteria2 + TLS на UDP/443; нативный QUIC или Salamander |
| Клиенты | Независимые ключи, HTTPS-подписки, ссылки и QR-коды |
| SSH | Отдельный администратор, вход по ключу, отключение root/пароля |
| Firewall | Нативный nftables с временным автоматическим откатом |
| TLS | Сертификат Let's Encrypt и проверенное автоматическое продление |
| Сеть | BBR + `fq` при поддержке и умеренные пределы UDP-буферов |
| Диск | Swap 1 ГБ при его отсутствии и журнал 200 МБ / 30 дней |
| Обновления | Автоматические обновления безопасности ОС и транзакционный sing-box update |

## Подписки

Каждый клиент получает непредсказуемый приватный URL подписки по HTTPS на
TCP/8443. Один URL отдаёт Base64-список VLESS/Hysteria2 либо готовый профиль
Mihomo в зависимости от `User-Agent`; формат Mihomo также доступен через
`/mihomo`. Маршрутизация, split tunneling и политика GeoIP остаются на стороне
клиента.

Совместимость и модель угроз описаны в
[docs/SUBSCRIPTIONS.md](docs/SUBSCRIPTIONS.md).

## Ограничения

- Ни один протокол, target или fingerprint не гарантирует обход любой фильтрации.
- Hysteria2 требует рабочего UDP и может замедляться в некоторых сетях.
- IPv6-профили, CDN-транспорты, port hopping, панели и статистика не настраиваются.
- Клиентская маршрутизация и TLS-фрагментация сервером не навязываются.
- Проверяйте оба транспорта в реальных Wi-Fi и мобильных сетях.

<details>
<summary><strong>Команды восстановления</strong></summary>

На свежей установке завершение выполняется автоматически. Используйте эти
команды только по прямому указанию диагностики:

```bash
sudo vpn finalize --yes
sudo vpn confirm-firewall --yes
sudo vpn rollback-firewall --yes
sudo vpn lockdown-ssh --yes
sudo vpn self-update /root/install-sing-box-server.sh
```

</details>

## Примечание о разработке

Проект создан с помощью вайб-кодинга и ИИ, а затем проверен, протестирован и
доработан на реальных VPS с Debian и Ubuntu. Перед использованием на чужой
инфраструктуре прочитайте код и оцените компромиссы.

## Лицензия

Установщик распространяется по [лицензии MIT](LICENSE). У sing-box и системных
пакетов сохраняются их собственные лицензии.
