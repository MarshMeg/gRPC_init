#!/bin/bash

# Проверяем, передан ли аргумент
if [ $# -eq 0 ]; then
    echo "Ошибка: Не указано название языка."
    echo "Использование:"
    echo "    $0 <lang_name>"
    exit 1
fi

lang_name="$1"
init_script="init/${lang_name}.sh"

# Проверяем, существует ли файл
if [ ! -f "$init_script" ]; then
    echo "Ошибка: Скрипт инициализации для языка '$lang_name' не найден."
    echo "Ожидаемый путь: $init_script"
    exit 2
fi

# Запускаем скрипт
echo "Запускаем инициализацию для языка: $lang_name"
bash "$init_script"