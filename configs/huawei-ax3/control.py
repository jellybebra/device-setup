"""One-shot control panel for Xray running on this user's Huawei router."""
import threading
import tkinter as tk
from tkinter import ttk
from router_console import Console

root = tk.Tk()
root.title("Huawei AX3 — VLESS MVP")
root.geometry("700x480")
root.minsize(600, 400)
ttk.Label(root, text="Huawei • правила действуют для всех подключённых устройств", font=("Segoe UI", 12)).pack(pady=12)
ttk.Label(root, text="Автозапуск настроен. После перезагрузки Huawei подожди около 75 секунд.").pack()
bar = ttk.Frame(root)
bar.pack(pady=14)
output = tk.Text(root, wrap="word", font=("Consolas", 10))
output.pack(fill="both", expand=True, padx=12, pady=(0,12))
buttons = []
def finish(text):
    output.delete("1.0", "end")
    output.insert("end", text)
    for b in buttons: b.config(state="normal")
def run(action):
    for b in buttons: b.config(state="disabled")
    output.delete("1.0", "end")
    output.insert("end", "Подключаюсь к 192.168.3.1…")
    def work():
        c = None
        try:
            c = Console()
            c.root()
            text = c.run("/bin/sh /data/mvp/mvp-service.sh " + action, 15)
            if action != "status":
                text += "\nКоманда отправлена. Через 30 секунд нажми «Статус».\n"
            root.after(0, finish, text)
        except Exception as exc:
            root.after(0, finish, "Ошибка: " + str(exc) + "\nПроверь кабель ПК → Huawei и адрес ПК 192.168.3.2.")
        finally:
            if c: c.close()
    threading.Thread(target=work, daemon=True).start()
for label, action in [("Включить", "on"), ("Профиль 1", "profile 1"), ("Профиль 2", "profile 2"), ("Прямой интернет", "off"), ("Статус", "status")]:
    b = ttk.Button(bar, text=label, command=lambda a=action: run(a))
    b.pack(side="left", padx=3)
    buttons.append(b)
run("status")
root.mainloop()
