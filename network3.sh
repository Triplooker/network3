channel_logo() {
  echo -e '\033[0;31m'
  echo -e 'Network3 Node Manager'
  echo -e '\e[0m'
}

restore_key() {
  echo "Введите ваш приватный ключ:"
  read -r private_key
  
  # Создаем директорию и сохраняем ключ
  mkdir -p $HOME/ubuntu-node/config
  echo "$private_key" > $HOME/ubuntu-node/config/private_key
  chmod 600 $HOME/ubuntu-node/config/private_key
  echo "Приватный ключ сохранен!"
}

download_node() {
  echo 'Начинаю установку...'
  
  echo -e "\nХотите использовать существующий приватный ключ? (y/n)"
  read -r use_existing_key
  
  cd $HOME
  
  sudo apt install lsof

  # Проверяем порты
  ports=(8082 1435)
  ports_in_use=()

  for port in "${ports[@]}"; do
    if [[ $(lsof -i :"$port" | wc -l) -gt 0 ]]; then
      process=$(lsof -i :"$port" | tail -n 1)
      ports_in_use+=("$port (используется: $process)")
    fi
  done

  if [ ${#ports_in_use[@]} -gt 0 ]; then
    echo -e "\n⚠️ Внимание! Следующие порты уже используются:"
    printf '%s\n' "${ports_in_use[@]}"
    echo -e "\nЭти порты могут быть заняты другими нодами. Установка прервана."
    echo "Пожалуйста, используйте другой сервер или освободите порты вручную."
    exit 1
  fi

  sudo apt update -y && sudo apt upgrade -y
  sudo apt install screen net-tools iptables jq curl wireguard-tools -y

  # Настраиваем файрвол
  setup_firewall
  
  # Удаляем старую установку если есть
  sudo rm -rf ubuntu-node*
  
  wget https://network3.io/ubuntu-node-v2.1.1.tar.gz
  tar -xvf ubuntu-node-v2.1.1.tar.gz
  sudo rm -rf ubuntu-node-v2.1.1.tar.gz

  cd ubuntu-node
  
  if [[ "$use_existing_key" == "y" ]]; then
    # Останавливаем ноду если запущена
    sudo bash manager.sh down 2>/dev/null
    
    echo "Введите ваш приватный ключ:"
    read -r private_key
    
    # Создаем директорию wireguard если её нет
    sudo mkdir -p /usr/local/etc/wireguard
    
    # Сохраняем ключ в правильное место
    echo "$private_key" | sudo tee /usr/local/etc/wireguard/utun.key > /dev/null
    sudo chmod 600 /usr/local/etc/wireguard/utun.key
    
    # Сохраняем ключ в конфигурацию WireGuard
    echo "[Interface]
PrivateKey = $private_key
ListenPort = 1435" > wg0.conf
    chmod 600 wg0.conf
    
    # Также сохраняем ключ в директорию config для совместимости
    mkdir -p config
    echo "$private_key" > config/private_key
    chmod 600 config/private_key
    
    echo "Приватный ключ сох��анен!"
    
    # Проверяем сохранение
    echo "Проверка конфигурации:"
    cat wg0.conf
    
    # Даем время на применение изменений
    sleep 5
  fi
  
  # Изменяем порты в конфигурации
  find . -type f -exec sed -i 's/:8080/:8082/g' {} \;
  find . -type f -exec sed -i 's/:1433/:1435/g' {} \;
}

# Добавим новую функцию для проверки статуса screen
check_screen_status() {
  echo -e "\nПроверяем screen сессии:"
  screen -ls | grep network3 || echo "Активных screen сессий не найдено"
}

# Модифицируем функцию launch_node()
launch_node() {
  cd $HOME/ubuntu-node
  
  # Проверяем и настраиваем файрвол перед запуском
  setup_firewall
  
  echo "Проверяем конфигурацию..."
  find . -type f -exec grep -l "8080\|1433" {} \; 2>/dev/null
  
  echo -e "\nТекущие настройки портов:"
  grep -r "8080\|8082\|1433\|1435" . 2>/dev/null
  
  echo -e "\nОстанавливаем предыдущий запуск..."
  sudo bash manager.sh down
  sleep 5
  
  echo -e "\nИзменяем порты в конфигурации..."
  find . -type f -exec sed -i 's/8080/8082/g' {} \;
  find . -type f -exec sed -i 's/1433/1435/g' {} \;
  
  echo -e "\nЗапускаем ноду..."
  # Запускаем в screen с уникальным именем
  SCREEN_NAME="network3_$(date +%s)"
  screen -dmS $SCREEN_NAME bash -c "cd $HOME/ubuntu-node && sudo bash manager.sh up; exec bash"
  
  echo "Ожидаем запуска (30 сек)..."
  sleep 30
  
  echo -e "\nПроверяем статус:"
  check_screen_status
  ps aux | grep -i "node" | grep -v grep
  sudo netstat -tulpn | grep -E "8082|1435"
  
  echo -e "\nПроверяем доступность портов..."
  for port in 8082 1435; do
    if nc -z localhost $port >/dev/null 2>&1; then
      echo "✅ Порт $port доступен локально"
    else
      echo "⚠️ Порт $port недоступен локально"
    fi
  done
  
  # После запуска проверяем статус
  echo -e "\nПроверяем сетевые настройки:"
  echo "1. Файрвол:"
  sudo ufw status | grep -E "8082|1435"
  
  echo -e "\n2. Порты:"
  sudo netstat -tulpn | grep -E "8082|1435"
  
  echo -e "\n3. WireGuard:"
  sudo wg show || echo "WireGuard не запущен"
}

stop_node() {
  cd $HOME/ubuntu-node
  echo "Останавливаем ноду..."
  sudo bash manager.sh down
  
  # Убиваем все оставшиеся процессы
  pkill -f "manager.sh up"
  
  # Очищаем WireGuard интерфейс
  sudo wg-quick down wg0 2>/dev/null
  sudo ip link delete wg0 2>/dev/null
  
  # Убиваем все screen сессии
  screen -ls | grep network3 | cut -d. -f1 | xargs -I % screen -S % -X quit
  
  echo "Нода остановлена"
}

# Модифицируем функцию check_points()
check_points() {
  my_ip=$(hostname -I | awk '{print $1}')
  
  echo "Проверяем процессы ноды..."
  ps aux | grep -i "node" | grep -v grep
  
  check_screen_status
  
  echo -e "\nПроверяем порты..."
  sudo netstat -tulpn | grep -E "8082|1435"
  
  echo -e "\n🌐 Статистика доступна в браузере:"
  echo "https://account.network3.ai/main?o=$my_ip:8082"
  echo -e "\nСкопируйте ссылку и откройте в браузере для просмотра поинтов"
}

check_private_key() {
  cd $HOME/ubuntu-node
  sudo bash manager.sh key
}

remove_node() {
  echo "Останавливаю ноду..."
  cd $HOME/ubuntu-node
  sudo bash manager.sh down
  
  echo "Убиваем screen сессии network3..."
  screen -ls | grep network3 | cut -d. -f1 | xargs -I % screen -S % -X quit
  
  echo "Останавливаем процессы на портах..."
  sudo kill $(lsof -t -i:8082) 2>/dev/null
  sudo kill $(lsof -t -i:1435) 2>/dev/null
  
  echo "Удаляю ключи WireGuard..."
  sudo rm -f /usr/local/etc/wireguard/utun.key
  sudo rm -f $HOME/ubuntu-node/wg0.conf
  sudo rm -f $HOME/ubuntu-node/config/private_key
  
  echo "Удаляю файлы ноды..."
  cd $HOME
  sudo rm -rf ubuntu-node
  
  echo "Нода и все ключи успешно удалены!"
}

exit_from_script() {
  exit 0
}

# Добавляем новую функцию для проверки логов
check_logs() {
  echo "Проверяем логи ноды..."
  
  if [ -d "$HOME/ubuntu-node" ]; then
    cd $HOME/ubuntu-node
    
    # Сначала проверяем screen сессии
    echo -e "\nАктивные screen сессии:"
    screen_sessions=$(screen -ls | grep network3)
    if [ ! -z "$screen_sessions" ]; then
      echo "$screen_sessions"
      
      echo -e "\nВыберите действие:"
      echo "1. Подключиться к screen сессии (Ctrl+A затем D для отключения)"
      echo "2. Проверить файлы логов"
      echo "3. Вернуться в меню"
      read -p "Ваш выбор: " screen_choice
      
      case $screen_choice in
        1)
          screen_id=$(echo "$screen_sessions" | awk '{print $1}' | cut -d. -f1)
          echo "Подключаемся к screen сессии... (Ctrl+A затем D для отключения)"
          sleep 2
          screen -r $screen_id
          return
          ;;
        2)
          # Продолжаем проверку файлов логов
          ;;
        3)
          return
          ;;
      esac
    fi
    
    # Проверяем разные возможные расположения логов
    log_files=(
      "./logs/node.log"
      "./log/node.log"
      "./node.log"
      "./logs/debug.log"
      "./manager.log"
      "./logs/manager.log"
      "./logs/output.log"
    )
    
    logs_found=false
    
    for log_file in "${log_files[@]}"; do
      if [ -f "$log_file" ]; then
        echo -e "\n📄 Найден файл логов: $log_file"
        echo "Выберите действие:"
        echo "1. Показать последние 20 строк"
        echo "2. Следить за логами в реальном времени (Ctrl+C для выхода)"
        echo "3. Пропустить этот файл"
        read -p "Ваш выбор: " log_choice
        
        case $log_choice in
          1)
            echo -e "\nПоследние 20 строк из $log_file:"
            tail -n 20 "$log_file"
            ;;
          2)
            echo -e "\nОтслеживание логов в реальном времени (Ctrl+C для выхода):"
            tail -f "$log_file"
            ;;
          3)
            continue
            ;;
        esac
        logs_found=true
      fi
    done
    
    if [ "$logs_found" = false ]; then
      echo "❌ Файлы логов не найдены"
      
      echo -e "\nПроверяем процессы ноды..."
      ps aux | grep -i "network3\|manager.sh" | grep -v grep
      
      echo -e "\nПроверяем последний вывод screen сессии:"
      for session in $(screen -ls | grep network3 | awk '{print $1}'); do
        echo -e "\nВывод сессии $session:"
        screen -S "$session" -X hardcopy /tmp/screen.log
        if [ -f /tmp/screen.log ]; then
          tail -n 20 /tmp/screen.log
          rm /tmp/screen.log
        fi
      done
    fi
  else
    echo "❌ Директо��ия ноды не найдена"
  fi
}

check_network() {
  echo "Диагностика сети..."
  
  echo -e "\n1. Проверка файрвола:"
  sudo ufw status | grep -E "8082|1435" || echo "Порты не найдены в UFW"
  
  echo -e "\n2. Проверка локальных портов:"
  sudo netstat -tulpn | grep -E "8082|1435" || echo "Порты не прослушиваются"
  
  echo -e "\n3. Проверка WireGuard:"
  sudo wg show || echo "WireGuard не запущен"
  
  echo -e "\n4. Проверка сетевых интерфейсов:"
  ip a | grep -E "wg0|inet"
  
  echo -e "\n5. Проверка маршрутизации:"
  ip route | grep wg0
  
  echo -e "\n6. Проверка доступности портов извне:"
  my_ip=$(curl -s ifconfig.me)
  echo "Проверяем порт 8082..."
  nc -zv $my_ip 8082 2>&1
  echo "Проверяем порт 1435..."
  nc -zvu $my_ip 1435 2>&1
  
  echo -e "\n7. Системные логи WireGuard:"
  sudo journalctl | grep -i "wireguard" | tail -n 10
}

# Добавляем новую функцию для настройки файрвола
setup_firewall() {
  echo "Настраиваем файрвол..."
  
  # Проверяем статус UFW
  if ! command -v ufw >/dev/null 2>&1; then
    echo "Устанавливаем UFW..."
    sudo apt update
    sudo apt install -y ufw
  fi
  
  # Проверяем и добавляем правила
  echo "Проверяем правила файрвола..."
  
  # Входящие соединения
  sudo ufw allow 8082/tcp comment 'Network3 Web Port'
  sudo ufw allow 1435/udp comment 'Network3 WireGuard Port'
  
  # Исходящие соединения
  sudo ufw allow out 8082/tcp
  sudo ufw allow out 1435/udp
  
  # Включаем файрвол если он выключен
  if sudo ufw status | grep -q "Status: inactive"; then
    echo "Активируем файрвол..."
    echo "y" | sudo ufw enable
  fi
  
  echo "Текущие правила файрвола:"
  sudo ufw status numbered
}

while true; do
    channel_logo
    sleep 2
    echo -e "\n\nМеню:"
    echo "1. 🔧 Установить ноду"
    echo "2. 🚀 Запустить ноду"
    echo "3. ⛔ Остановить ноду"
    echo "4. 🎯 Проверить количество поинтов"
    echo "5. 🔑 Посмотреть приватный ключ"
    echo "6. 🗑️ Удалить ноду"
    echo "7. 📋 Проверить логи"
    echo "8. 🌐 Проверить сеть"
    echo -e "9. ❌ Выйти из скрипта\n"
    read -p "Выберите пункт меню: " choice

    case $choice in
      1)
        download_node
        ;;
      2)
        launch_node
        ;;
      3)
        stop_node
        ;;
      4)
        check_points
        ;;
      5)
        check_private_key
        ;;
      6)
        remove_node
        ;;
      7)
        check_logs
        ;;
      8)
        check_network
        ;;
      9)
        exit_from_script
        ;;
      *)
        echo "Неверный пункт. Пожалуйста, выберите правильную цифру в меню."
        ;;
    esac
  done
