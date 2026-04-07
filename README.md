# 🛠️ Zabbix Maintenance Handler

[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Zabbix Version](https://img.shields.io/badge/zabbix-7.0-green.svg)](https://www.zabbix.com/documentation/7.0)
[![Shell Script](https://img.shields.io/badge/shell-Bash-blue.svg)](https://www.gnu.org/software/bash/)
[![JavaScript](https://img.shields.io/badge/js-Duktape-yellow.svg)](https://duktape.org/)

> Herramienta CLI para gestionar mantenimientos en Zabbix de forma automatizada, segura y auditable.

---

## 📋 Tabla de Contenidos

- [Descripción](#-descripción)
- [Características](#-características)
- [Requisitos](#-requisitos)
- [Instalación](#-instalación)
- [Configuración](#-configuración)
- [Uso](#-uso)
  - [Crear mantenimiento](#crear-mantenimiento)
  - [Actualizar mantenimiento](#actualizar-mantenimiento)
  - [Eliminar mantenimiento](#eliminar-mantenimiento)
  - [Listar mantenimientos](#listar-mantenimientos)
- [Referencia de Comandos](#-referencia-de-comandos)
- [Registro y Auditoría](#-registro-y-auditoría)
- [Estructura del Proyecto](#-estructura-del-proyecto)
- [Contribuir](#-contribuir)
- [Licencia](#-licencia)
- [Soporte](#-soporte)

---

## 📝 Descripción

**Zabbix Maintenance Handler** es una herramienta de línea de comandos diseñada para simplificar y estandarizar la gestión de mantenimientos en Zabbix 7.0+. Permite crear, actualizar, eliminar y listar mantenimientos de forma programática, integrándose con flujos de trabajo DevOps y operaciones IT.

El proyecto está construido con:
- **Bash**: Para la lógica principal, parseo de argumentos y orquestación.
- **JavaScript (Duktape)**: Para interactuar con la API de Zabbix mediante `zabbix_js`, el motor embebido en Zabbix.

---

## ✨ Características

### Funcionalidades principales
| Característica | Descripción |
|---------------|-------------|
| ✅ **CRUD completo** | Crear, leer, actualizar y eliminar mantenimientos |
| ✅ **Autenticación flexible** | Soporta login con usuario/contraseña o API Token |
| ✅ **Prefijo automático** | Todos los mantenimientos creados llevan un prefijo configurable para identificación |
| ✅ **Auditoría integrada** | Cada operación registra quién la realizó y cuándo (`performed_by`, `performed_at`) |
| ✅ **Logging a Zabbix** | Resultados enviados a items tipo *Zabbix trapper* para histórico y alertas |
| ✅ **Formatos flexibles** | Fechas en timestamp Unix o `YYYY-MM-DD HH:MM:SS`; períodos en `30m`, `2h`, `1d`, `1w` |
| ✅ **Manejo de errores claro** | Mensajes descriptivos en stdout y en registros de Zabbix |
| ✅ **Ayuda contextual** | `--help` disponible para cada subcomando |

### Beneficios operativos
- 🔒 **Seguridad**: Solo opera sobre mantenimientos con prefijo configurado, evitando modificaciones accidentales.
- 📊 **Visibilidad**: Resultados centralizados en Zabbix para monitoreo y reporting.
- ⚡ **Automatización**: Ideal para integrarse con pipelines CI/CD, cron jobs o scripts de orquestación.
- 🧩 **Extensibilidad**: Código modular y documentado para facilitar futuras ampliaciones.

---

## 🛠️ Requisitos

### Software
| Componente | Versión mínima | Notas |
|-----------|---------------|-------|
| Bash | 4.0+ | Con soporte para arrays asociativos |
| Zabbix Server/Proxy | 7.0+ | Con `zabbix_js` habilitado |
| jq | 1.6+ | Para procesamiento de JSON en Bash |
| curl / wget | - | Para llamadas HTTP si se usan funciones externas |

### Permisos en Zabbix
El usuario o token utilizado debe tener permisos para:
- `maintenance.create`, `maintenance.update`, `maintenance.delete`, `maintenance.get`
- `host.get`, `hostgroup.get` (para resolución de nombres)
- `item.get`, `trap.receive` (para logging a Zabbix)

---

## 📦 Instalación

### 1. Clonar el repositorio
```bash
git clone https://github.com/CUSTOSMonitoring/zbx-maintenance.git
cd zbx-maintenance
```

### 2. Verificar dependencias
```bash
# Verificar Bash
bash --version

# Verificar jq
jq --version

# Verificar zabbix_js (desde un entorno con acceso a Zabbix)
which zabbix_js
```

### 3. Configurar permisos de ejecución
```bash
chmod +x src/run_maintenance.sh
```

### 4. (Opcional) Agregar al PATH
```bash
# En ~/.bashrc o ~/.zshrc
export PATH="$PATH:/ruta/a/zbx-maintenance-dev/src"
```

---

## ⚙️ Configuración

### Archivo de configuración: `config/default_params.conf`

```bash
# Zabbix API
ZBX_URL="https://tu-zabbix.example.com/api_jsonrpc.php"
ZBX_USER="tu_usuario"
ZBX_PASSWORD="tu_contraseña"
# O usar API Token (recomendado para producción)
# ZBX_APITOKEN="tu_api_token_aqui"

# Prefijo para mantenimientos gestionados por este proyecto
PREFIX_MAINTENANCE_NAME="[Web Mantenimientos] "

# Ruta al handler JavaScript
MAINTENANCE_HANDLER_JS="/ruta/completa/src/maintenance_handler.js"
```

### Variables de entorno (alternativa)
También puedes configurar los parámetros mediante variables de entorno:
```bash
export ZBX_URL="https://tu-zabbix.example.com/api_jsonrpc.php"
export ZBX_APITOKEN="tu_api_token"
export PREFIX_MAINTENANCE_NAME="[Web Mantenimientos] "
```

### Prioridad de configuración
1.  Flags en línea de comandos (`--zbx-url`, `--zbx-apitoken`, etc.)
2.  Variables de entorno
3.  Archivo `config/default_params.conf`

---

## 🚀 Uso

### Sintaxis general
```bash
./src/run_maintenance.sh [OPCIONES_GLOBALES] <comando> [OPCIONES_DEL_COMANDO]
```

### Opciones globales
| Opción | Descripción |
|--------|-------------|
| `-u, --zbx-url URL` | URL de la API de Zabbix |
| `-U, --zbx-user USER` | Usuario para autenticación por sesión |
| `-P, --zbx-password PASS` | Contraseña para autenticación por sesión |
| `-t, --zbx-apitoken TOKEN` | API Token (alternativa a usuario/contraseña) |
| `-c, --config PATH` | Ruta al archivo de configuración |
| `-h, --help` | Mostrar ayuda general |

### Comandos disponibles
```bash
create   # Crear un nuevo mantenimiento
update   # Actualizar un mantenimiento existente
delete   # Eliminar un mantenimiento existente
list     # Listar mantenimientos gestionados por este proyecto
```

---

### ➕ Crear mantenimiento

```bash
./src/run_maintenance.sh create [OPCIONES]
```

#### Opciones
| Opción | Requerido | Descripción |
|--------|-----------|-------------|
| `-n, --name NAME` | ✅ | Nombre del mantenimiento (sin prefijo) |
| `--period PERIOD` | ✅ | Duración del período (`30m`, `2h`, `1d`, `1w`) |
| `--active-since TIMESTAMP` | ❌ | Inicio del mantenimiento. Por defecto: ahora |
| `--active-till TIMESTAMP` | ❌ | Fin del mantenimiento. Por defecto: ahora + 3 años |
| `--type TYPE` | ❌ | Tipo: `0`=Normal, `1`=No Data. Por defecto: `0` |
| `--startdate STARTDATE` | ❌ | Inicio del primer período. Por defecto: ahora |
| `--description TEXT` | ❌ | Descripción del mantenimiento |
| `-H, --hostnames LIST` | ❌ | Hosts separados por comas |
| `-G, --groupnames LIST` | ❌ | Grupos separados por comas |
| `-S, --sector NAME` | ❌ | Sector para logging en Zabbix |

#### Ejemplos
```bash
# Mínimo
./src/run_maintenance.sh \
  --zbx-apitoken "abc123" \
  create \
  --name "Mantenimiento Web" \
  --period 2h \
  --hostnames "web01,web02" \
  --sector "Infraestructura"

# Completo
./src/run_maintenance.sh \
  --zbx-url "https://zabbix.local/api_jsonrpc.php" \
  --zbx-user "admin" \
  --zbx-password "secret" \
  create \
  --name "Actualización Base de Datos" \
  --active-since "2026-01-15 02:00:00" \
  --active-till "2026-01-15 06:00:00" \
  --type 1 \
  --period 4h \
  --startdate "2026-01-15 02:30:00" \
  --description "Mantenimiento nocturno para actualizaciones de esquema" \
  --hostnames "db-prod-01,db-prod-02" \
  --groupnames "Producción,Bases de Datos" \
  --sector "DBA"
```

> 💡 **Nota**: El script agrega automáticamente el prefijo configurado al nombre del mantenimiento creado.

---

### ✏️ Actualizar mantenimiento

```bash
./src/run_maintenance.sh update [OPCIONES]
```

#### Opciones
| Opción | Requerido | Descripción |
|--------|-----------|-------------|
| `-n, --name NAME` | ✅ | Nombre del mantenimiento (**con prefijo**) |
| `--period PERIOD` | ❌ | Nueva duración del período |
| `--startdate STARTDATE` | ❌ | Nuevo inicio del período |
| `--active-since TIMESTAMP` | ❌ | Nuevo inicio del mantenimiento |
| `--active-till TIMESTAMP` | ❌ | Nuevo fin del mantenimiento |
| `--type TYPE` | ❌ | Nuevo tipo: `0` o `1` |
| `--description TEXT` | ❌ | Nueva descripción |
| `-H, --hostnames LIST` | ❌ | Nueva lista de hosts (reemplaza existente) |
| `-G, --groupnames LIST` | ❌ | Nueva lista de grupos (reemplaza existente) |
| `-S, --sector NAME` | ❌ | Sector para logging en Zabbix |

#### Ejemplos
```bash
# Actualizar período y hosts
./src/run_maintenance.sh \
  --zbx-apitoken "abc123" \
  update \
  --name "[Web Mantenimientos] Mantenimiento Web" \
  --period 4h \
  --hostnames "web01,web03" \
  --sector "Infraestructura"

# Actualizar múltiples campos
./src/run_maintenance.sh \
  --zbx-apitoken "abc123" \
  update \
  --name "[Web Mantenimientos] Mantenimiento Web" \
  --active-since "2026-02-01 00:00:00" \
  --description "Descripción actualizada post-migración" \
  --sector "Infraestructura"
```

> ⚠️ **Importante**: Para `update` y `delete`, debes incluir **manualmente** el prefijo en el nombre del mantenimiento.

---

### 🗑️ Eliminar mantenimiento

```bash
./src/run_maintenance.sh delete [OPCIONES]
```

#### Opciones
| Opción | Requerido | Descripción |
|--------|-----------|-------------|
| `-n, --name NAME` | ✅ | Nombre del mantenimiento (**con prefijo**) |
| `-S, --sector NAME` | ❌ | Sector para logging en Zabbix |

#### Ejemplo
```bash
./src/run_maintenance.sh \
  --zbx-apitoken "abc123" \
  delete \
  --name "[Web Mantenimientos] Mantenimiento Web" \
  --sector "Infraestructura"
```

> ⚠️ **Advertencia**: La eliminación es **permanente** y no se puede deshacer. Verifica cuidadosamente antes de ejecutar.

---

### 📋 Listar mantenimientos

```bash
./src/run_maintenance.sh list
```

- No requiere parámetros adicionales.
- Filtra mantenimientos por el prefijo configurado (`PREFIX_MAINTENANCE_NAME`).
- Devuelve un JSON con todos los detalles de cada mantenimiento.

#### Ejemplo
```bash
./src/run_maintenance.sh \
  --zbx-apitoken "abc123" \
  list
```

#### Salida (ejemplo)
```json
[
  {
    "maintenanceid": "231",
    "name": "[Web Mantenimientos] Mantenimiento Web",
    "maintenance_type": "0",
    "description": "Mantenimiento programado",
    "active_since": "1704067200",
    "active_till": "1735689600",
    "timeperiods": [...],
    "hosts": [...],
    "hostgroups": [...]
  }
]
```

---

## 📚 Referencia de Comandos

### Formato de fechas y períodos

| Campo | Formatos aceptados | Ejemplos |
|-------|-------------------|----------|
| `--active-since`, `--active-till`, `--startdate` | Unix timestamp **o** `YYYY-MM-DD HH:MM:SS` | `1704067200`, `"2026-01-01 00:00:00"` |
| `--period` | Duración relativa | `30m`, `2h`, `1d`, `1w` |

### Códigos de salida
| Código | Significado |
|--------|-------------|
| `0` | Éxito |
| `1` | Error (detalles en stderr) |

### Mensajes de auditoría
Cada operación exitosa o fallida incluye en su registro:
```json
{
  "performed_by": "usuario_ejecutor",
  "performed_at": "2026-04-07 14:30:00"
}
```

---

## 📊 Registro y Auditoría

### Logging a Zabbix
Si se especifica `--sector NAME`, el resultado de cada operación se envía a un item (previamente creado) tipo *Zabbix trapper* con:
- **Host**: `Registros de Mantenimientos` (configurable)
- **Key**: `mantenimientos.{sector}`
- **Contenido**: JSON con modo, estado, mensaje y metadatos de auditoría

### Ejemplo de registro exitoso
```json
{
  "mode": "create_maintenance",
  "status": "success",
  "message": {
    "maintenanceids": ["240"]
  },
  "performed_by": "xferema",
  "performed_at": "2026-04-07 14:30:00"
}
```

### Ejemplo de registro con error
```json
{
  "mode": "update_maintenance",
  "status": "error",
  "message": {
    "error": "Mantenimiento no encontrado para actualizar: ..."
  },
  "performed_by": "xferema",
  "performed_at": "2026-04-07 14:30:00"
}
```

---

## 📁 Estructura del Proyecto

```
zbx-maintenance-dev/
├── README.md                 # Este archivo
├── LICENSE                   # Licencia MIT
├── config/
│   └── default_params.conf   # Configuración por defecto
├── src/
│   ├── run_maintenance.sh    # Script principal (Bash)
│   └── maintenance_handler.js # Handler para zabbix_js (JavaScript/Duktape)
├── test/
│   ├── t0-list.test          # Prueba de listado
│   ├── t1-create.test        # Prueba de creación
│   ├── t1-update.test        # Prueba de actualización
│   ├── t2-create.test        # Prueba de creación v2
│   ├── t2-update.test        # Prueba de actualización v2
│   ├── t3-create-fail.test   # Prueba de error en creación
│   └── t3-update-fail.test   # Prueba de error en actualización
└── docs/                     # Documentación adicional (futuro)
```

---

## 🤝 Contribuir

¡Las contribuciones son bienvenidas! Si deseas colaborar:

1.  Haz fork del repositorio.
2.  Crea una rama para tu feature: `git checkout -b feature/nueva-funcionalidad`.
3.  Realiza tus cambios y commitea siguiendo [Conventional Commits](https://www.conventionalcommits.org/).
4.  Ejecuta pruebas locales con los scripts en `test/`.
5.  Abre un Pull Request describiendo los cambios.

### Estándares de código
- **Bash**: Sigue [ShellCheck](https://www.shellcheck.net/) para buenas prácticas.
- **JavaScript (Duktape)**: Evita características no soportadas por el motor embebido (ej: `print`, `console.log`).
- **Commits**: Usa mensajes descriptivos: `feat(description): agrega soporte para X`.

---

## 📜 Licencia

Este proyecto está licenciado bajo la [Licencia MIT](LICENSE).  
Eres libre de usar, modificar y distribuir este software, sujeto a los términos de la licencia.

---

## 🆘 Soporte

### Problemas comunes
| Síntoma | Posible causa | Solución |
|---------|--------------|----------|
| `jq: command not found` | jq no instalado | `sudo apt install jq` o `brew install jq` |
| `zabbix_js: command not found` | Script ejecutado fuera de entorno Zabbix | Ejecutar desde un script de Zabbix o configurar PATH |
| `Error: Parámetros inválidos` | Formato de fecha incorrecto | Usar timestamp Unix o `YYYY-MM-DD HH:MM:SS` |
| `Mantenimiento no encontrado` | Prefijo faltante en update/delete | Incluir `[Web Mantenimientos] ` en el nombre |

### ¿Necesitas ayuda?
- 📖 Consulta la [documentación oficial de Zabbix API](https://www.zabbix.com/documentation/7.0/en/manual/api)
- 🐛 Reporta bugs en [Issues](https://github.com/tu-usuario/zbx-maintenance-dev/issues)
- 💬 Discute ideas en [Discussions](https://github.com/tu-usuario/zbx-maintenance-dev/discussions)

---

