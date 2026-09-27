# نصب MikroTik CHR روی Ubuntu

اگر از طریق پروایدر امکان نصب مستقیم MikroTik را ندارید، می‌توانید با استفاده از این اسکریپت آخرین نسخه Stable میکروتیک CHR را مستقیماً روی سرور Ubuntu نصب و استفاده کنید.

> ⚠️ توجه: با اجرای اسکریپت، Ubuntu و اطلاعات روی دیسک سرور پاک می‌شود.

## نصب

دستور زیر را با کاربر `root` اجرا کنید:

```bash
curl -fsSL https://raw.githubusercontent.com/REZA-ZAMANIAN/Ubuntu-to-Mikrotik/main/install-chr.sh -o /root/install-chr.sh && bash /root/install-chr.sh
```

بعد از اتمام نصب، این پیام نمایش داده می‌شود:

```text
ما رفتیم بای 👋
Power off then power on
```

در این مرحله از پنل پروایدر، سرور را **Power Off** کرده و دوباره **Power On** کنید.

بعد از بالا آمدن MikroTik، به آن متصل شوید.

اطلاعات ورود اولیه:

```text
Username: admin
Password: خالی
```

بعد از ورود، حتماً برای کاربر `admin` پسورد تعیین کنید.

موفق باشید 🌹
