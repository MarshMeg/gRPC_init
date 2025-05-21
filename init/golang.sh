#!/bin/bash

set -e

# Параметры
AUTO_MODE=false
PROTO_REPO=""
PROJECT_NAME=""

# Парсим аргументы
while [[ $# -gt 0 ]]; do
    case "$1" in
        --auto)
            AUTO_MODE=true
            shift
            ;;
        --proto-repo=*)
            PROTO_REPO="${1#*=}"
            shift
            ;;
        --project-name=*)
            PROJECT_NAME="${1#*=}"
            shift
            ;;
        *)
            echo "Неизвестный аргумент: $1"
            exit 1
            ;;
    esac
done

# Функция для вывода ошибки и выхода
error_exit() {
    echo "Ошибка: $1"
    exit 1
}

# 1. Получаем название проекта
if [ -z "$PROJECT_NAME" ]; then
    if [ "$AUTO_MODE" = true ]; then
        error_exit "В автоматическом режиме требуется указать --project-name"
    fi
    read -rp "Введите название проекта (для go.mod): " PROJECT_NAME
fi

# 2. Получаем ссылку на репозиторий с .proto файлами
if [ -z "$PROTO_REPO" ]; then
    if [ "$AUTO_MODE" = true ]; then
        error_exit "В автоматическом режиме требуется указать --proto-repo"
    fi
    read -rp "Введите URL репозитория с .proto файлами: " PROTO_REPO
fi

# 3. Инициализируем git (если еще не инициализирован)
if [ ! -d .git ]; then
    echo "Инициализируем git репозиторий..."
    git init || error_exit "Не удалось инициализировать git репозиторий"
fi

# 4. Добавляем submodule с .proto файлами
echo "Добавляем git submodule с .proto файлами..."
git submodule add "$PROTO_REPO" proto || error_exit "Не удалось добавить git submodule"

# 5. Создаем структуру проекта
echo "Создаем структуру проекта..."
mkdir -p cmd/server internal/{server,service,db,utils} pkg/{pb,config} api

# 6. Инициализируем go.mod
echo "Инициализируем go.mod..."
go mod init "github.com/$(git config user.name)/$PROJECT_NAME" || {
    # Если не удалось получить имя пользователя из git config
    go mod init "github.com/unknown/$PROJECT_NAME"
}

# 7. Устанавливаем зависимости
echo "Устанавливаем зависимости..."
go get -v \
    google.golang.org/grpc \
    google.golang.org/protobuf \
    github.com/jmoiron/sqlx \
    github.com/lib/pq

# 8. Устанавливаем protoc-gen-go
echo "Устанавливаем protoc-gen-go..."
go install google.golang.org/protobuf/cmd/protoc-gen-go@latest
go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@latest

# 9. Генерируем код из .proto файлов
echo "Генерируем Go код из .proto файлов..."
protoc --go_out=. --go-grpc_out=. proto/*.proto || {
    echo "Предупреждение: Не удалось сгенерировать код из .proto файлов"
}

# 10. Создаем основные файлы проекта

# server.go
cat > internal/server/server.go <<'EOL'
package server

import (
	"context"
	"net"

	"google.golang.org/grpc"
)

type Server struct {
	grpcServer *grpc.Server
}

func New() *Server {
	return &Server{
		grpcServer: grpc.NewServer(),
	}
}

func (s *Server) Start(addr string) error {
	lis, err := net.Listen("tcp", addr)
	if err != nil {
		return err
	}
	return s.grpcServer.Serve(lis)
}

func (s *Server) Stop() {
	s.grpcServer.GracefulStop()
}

func (s *Server) RegisterService(desc *grpc.ServiceDesc, impl interface{}) {
	s.grpcServer.RegisterService(desc, impl)
}
EOL

# service.go
cat > internal/service/service.go <<'EOL'
package service

import (
	"context"

	"github.com/jmoiron/sqlx"
)

type Service struct {
	db *sqlx.DB
}

func New(db *sqlx.DB) *Service {
	return &Service{db: db}
}

// Add your service methods here
EOL

# db.go
cat > internal/db/db.go <<'EOL'
package db

import (
	"fmt"
	"os"

	"github.com/jmoiron/sqlx"
	_ "github.com/lib/pq"
)

type Config struct {
	Host     string
	Port     string
	User     string
	Password string
	DBName   string
	SSLMode  string
}

func NewPostgres(cfg Config) (*sqlx.DB, error) {
	connStr := fmt.Sprintf(
		"host=%s port=%s user=%s password=%s dbname=%s sslmode=%s",
		cfg.Host, cfg.Port, cfg.User, cfg.Password, cfg.DBName, cfg.SSLMode,
	)

	db, err := sqlx.Connect("postgres", connStr)
	if err != nil {
		return nil, fmt.Errorf("failed to connect to database: %w", err)
	}

	return db, nil
}

func ConfigFromEnv() Config {
	return Config{
		Host:     getEnv("DB_HOST", "localhost"),
		Port:     getEnv("DB_PORT", "5432"),
		User:     getEnv("DB_USER", "postgres"),
		Password: getEnv("DB_PASSWORD", "postgres"),
		DBName:   getEnv("DB_NAME", "postgres"),
		SSLMode:  getEnv("DB_SSLMODE", "disable"),
	}
}

func getEnv(key, defaultValue string) string {
	if value, exists := os.LookupEnv(key); exists {
		return value
	}
	return defaultValue
}
EOL

# utils.go
cat > internal/utils/utils.go <<'EOL'
package utils

import (
	"context"
	"time"
)

func ContextWithTimeout(timeout time.Duration) (context.Context, context.CancelFunc) {
	return context.WithTimeout(context.Background(), timeout)
}

// Add other utility functions here
EOL

# run.go
cat > cmd/server/run.go <<'EOL'
package main

import (
	"log"
	"os"
	"os/signal"
	"syscall"

	"{{MODULE_PATH}}/internal/db"
	"{{MODULE_PATH}}/internal/server"
	"{{MODULE_PATH}}/internal/service"
)

func main() {
	// Database configuration
	dbCfg := db.ConfigFromEnv()
	
	// Initialize database
	database, err := db.NewPostgres(dbCfg)
	if err != nil {
		log.Fatalf("Failed to connect to database: %v", err)
	}
	defer database.Close()

	// Initialize services
	svc := service.New(database)

	// Initialize server
	srv := server.New()
	
	// Register your gRPC services here
	// pb.RegisterYourServiceServer(srv.GRPCServer(), svc)

	// Start server
	go func() {
		if err := srv.Start(":50051"); err != nil {
			log.Fatalf("Failed to start server: %v", err)
		}
	}()

	log.Println("Server started on :50051")

	// Wait for interrupt signal
	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	<-quit

	// Graceful shutdown
	srv.Stop()
	log.Println("Server stopped gracefully")
}
EOL

# main.go
cat > cmd/server/main.go <<'EOL'
package main

import _ "{{MODULE_PATH}}/cmd/server"
EOL

# Заменяем плейсхолдеры в файлах
MODULE_PATH=$(go list -m)
find . -type f -name "*.go" -exec sed -i "s|{{MODULE_PATH}}|$MODULE_PATH|g" {} \;

# 11. Создаем Makefile
cat > Makefile <<'EOL'
.PHONY: run build proto clean

run:
	go run cmd/server/run.go

build:
	go build -o bin/server cmd/server/run.go

proto:
	protoc --go_out=. --go-grpc_out=. proto/*.proto

clean:
	rm -rf bin/
EOL

# 12. Создаем скрипт для удаления инициализации
cat > del_init.sh <<'EOL'
#!/bin/bash

# Удаляем себя и init скрипт
rm -f init/go.sh del_init.sh

# Удаляем из git истории (если нужно)
if [ -d .git ]; then
    git filter-branch --force --index-filter \
        "git rm --cached --ignore-unmatch init/go.sh del_init.sh" \
        --prune-empty --tag-name-filter cat -- --all
    git reflog expire --expire=now --all
    git gc --prune=now --aggressive
fi

echo "Init скрипты удалены"
EOL

chmod +x del_init.sh

# 13. Запускаем del_init.sh в конце
echo "Инициализация завершена. Очищаем init скрипты..."

echo ""
echo "Проект $PROJECT_NAME успешно создан!"
echo "Структура проекта:"
tree -L 3
echo ""
echo "Для запуска:"
echo "1. Настройте переменные окружения для базы данных"
echo "2. Выполните: make run"
echo ""
echo "Не забудьте зарегистрировать ваши gRPC сервисы в run.go!"

bash init/del_init.sh