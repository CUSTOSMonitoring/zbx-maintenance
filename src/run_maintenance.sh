#!/bin/bash
# ==================================================================================
# run_maintenance.sh
# Script para ejecutar maintenance_handler.js vía zabbix_js
# Refactorizado para soportar subcomandos: create, update, delete, list.
# Recibe parámetros por banderas según el subcomando elegido.
# Utiliza la API de Zabbix para gestionar mantenimientos y registrar resultados.
# ==================================================================================

# =============================================================================
# 1. === CONSTANTES Y VARIABLES GLOBALES (opcional, al inicio si son pocas) ===
# =============================================================================

# Variables generales (autenticación, config)
ZBX_URL=""
ZBX_USER="" # Para login
ZBX_PASSWORD="" # Para login
ZBX_APITOKEN="" # Para API (puede ser API Token o Session Token)
CONFIG_FILE="" # Ruta al archivo de configuración
PROJECT_ROOT=""
MAINTENANCE_HANDLER_JS=""

# Variables temporales para parseo de argumentos globales (antes de subcomandos)
RAW_ZBX_URL=""
RAW_ZBX_USER=""
RAW_ZBX_PASSWORD=""
RAW_ZBX_APITOKEN=""

# Variables específicas por subcomando (declaradas vacías aquí)
# CREATE
CREATE_NAME=""
CREATE_ACTIVE_SINCE=""
CREATE_ACTIVE_TILL=""
CREATE_TYPE=""
CREATE_PERIOD=""
CREATE_STARTDATE=""
CREATE_HOSTNAMES=""
CREATE_GROUPNAMES=""
# UPDATE
UPDATE_NAME=""
UPDATE_PERIOD=""
UPDATE_STARTDATE=""
UPDATE_HOSTNAMES=""
UPDATE_GROUPNAMES=""
UPDATE_SECTOR="" # Necesario para el registro en Zabbix
# DELETE
DELETE_NAME=""
# LIST
LIST_FILTER=""

# Variable para almacenar el subcomando elegido
COMMAND=""

# =============================================================================
# 2. === FUNCIONES ===
# =============================================================================

# --- Funciones auxiliares de Bash ---

# Función para encontrar la raíz del proyecto
find_project_root() {
    local current_dir="$PWD"
    while [[ "$current_dir" != "/" ]]; do
        # Buscamos un marcador claro del proyecto, como la carpeta config
        if [[ -d "$current_dir/config" ]]; then
            echo "$current_dir"
            return 0
        fi
        current_dir="$(dirname "$current_dir")"
    done
    echo "Error: No se encontró la raíz del proyecto (falta carpeta 'config')" >&2
    exit 1
}

# Función para escapar cadenas para JSON
escape_json() {
    echo "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

# Función para convertir unidades de tiempo a segundos
parse_time_to_seconds() {
    local input="$1"
    local value unit seconds=0

    # Si el input está vacío, retornar error
    if [[ -z "$input" ]]; then
        echo "Error: entrada vacía" >&2
        return 1
    fi

    # Verificar si es solo un número (asumimos segundos)
    if [[ "$input" =~ ^[0-9]+$ ]]; then
        echo "$input"
        return 0
    fi

    # Validar formato: debe ser número seguido de una sola letra: d, h, m, s (minúsculas)
    if ! [[ "$input" =~ ^([0-9]+)([dhms])$ ]]; then
        echo "Error: formato inválido. Usa <número><unidad> donde unidad es d, h, m o s. Ej: 1d, 30m" >&2
        return 1
    fi

    value="${BASH_REMATCH[1]}"
    unit="${BASH_REMATCH[2]}"

    case "$unit" in
        s) seconds="$value" ;;
        m) seconds=$((value * 60)) ;;
        h) seconds=$((value * 3600)) ;;
        d) seconds=$((value * 86400)) ;;
    esac

    echo "$seconds"
    return 0
}

# Función para convertir fecha a timestamp
parse_datetime_to_timestamp() {
    local input="$1"
    local date_part time_part datetime formatted

    # Validamos que se haya recibido entrada
    if [[ -z "$input" ]]; then
        echo "Error: no se proporcionó fecha" >&2
        return 1
    fi

    # Removemos los espacios extra al inicio y final
    input=$(echo "$input" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

    # Separamos por espacio para ver si tiene fecha y hora
    if [[ "$input" =~ ^([0-9]{4})-([0-9]{2})-([0-9]{2})([[:space:]]+([0-9]{2}):([0-9]{2}):([0-9]{2}))?$ ]]; then
        date_part="${BASH_REMATCH[1]}-${BASH_REMATCH[2]}-${BASH_REMATCH[3]}"
        if [ "${#BASH_REMATCH[@]}" -ge 6 ] && [ -n "${BASH_REMATCH[5]}" ]; then
            time_part="${BASH_REMATCH[5]}:${BASH_REMATCH[6]}:${BASH_REMATCH[7]}"
        else
            time_part="00:00:00"
        fi

        datetime="$date_part $time_part"

        # Convertimos a timestamp
        if timestamp=$(date -d "$datetime" +%s 2>/dev/null); then
            echo "$timestamp"
            return 0
        else
            echo "Error: fecha u hora inválida: $datetime" >&2
            return 1
        fi
    else
        echo "Error: formato de fecha inválido. Usa yyyy-mm-dd o yyyy-mm-dd hh:mm:00" >&2
        return 1
    fi
}

# --- Funciones de autenticación Zabbix (sesión) ---

# Función para iniciar sesión en Zabbix y obtener un session token
zbx_login() {
    local url="$1"
    local username="$2"
    local password="$3"

    # Validación de params de entrada
    if [[ -z "$url" || -z "$username" || -z "$password" ]]; then
        echo "Error: Faltan parámetros en zbx_login" >&2
        return 1
    fi

    # Construimos el body de la solicitud de login
    local json_body
    json_body=$(jq -n --arg user "$username" --arg pass "$password" '
        {
            jsonrpc: "2.0",
            method: "user.login",
            params: {
                username: $user,
                password: $pass
            },
            id: 1
        }')

    # Hacemos la solicitud POST
    local response
    response=$(curl -k -w "\n" -s -X POST \
         -H "Content-Type: application/json-rpc" \
         -d "$json_body" \
         "$url")

    local curl_exit=$?
    if [[ $curl_exit -ne 0 ]]; then
        echo "Error: Fallo en la conexión HTTP al intentar iniciar sesión." >&2
        return 1
    fi

    # Verificar si Zabbix devolvió un error
    if echo "$response" | jq -e '.error' >/dev/null 2>&1; then
        echo "Error de Zabbix en login: $(echo "$response" | jq -r '.error.data // .error.message // "desconocido"')" >&2
        return 1
    fi

    # Extraer y devolver el session token
    echo "$response" | jq -r '.result // empty'
    return 0
}

# Función para cerrar sesión en Zabbix
zbx_logout() {
    local url="$1"
    local session_token="$2"

    # Validación de params de entrada
    if [[ -z "$url" || -z "$session_token" ]]; then
        echo "Error: Faltan parámetros en zbx_logout" >&2
        return 1
    fi

    # Construimos el body de la solicitud de logout
    local json_body
    json_body=$(jq -n --arg sess "$session_token" '
        {
            jsonrpc: "2.0",
            method: "user.logout",
            params: {},
            auth: $sess,
            id: 1
        }')

    # Hacemos la solicitud POST
    local response
    response=$(curl -k -w "\n" -s -X POST \
         -H "Content-Type: application/json-rpc" \
         -d "$json_body" \
         "$url")

    local curl_exit=$?
    if [[ $curl_exit -ne 0 ]]; then
        echo "Error: Fallo en la conexión HTTP al intentar cerrar sesión." >&2
        return 1
    fi

    # Verificar si Zabbix devolvió un error
    if echo "$response" | jq -e '.error' >/dev/null 2>&1; then
        echo "Advertencia: Error de Zabbix en logout: $(echo "$response" | jq -r '.error.data // .error.message // "desconocido"')" >&2
        # Devolvemos el error pero no detenemos el script principal
        return 0 # Permitimos continuar
    fi

    # Imprimimos el result, puede ser vacío o un ID
    echo "$response" | jq -r '.result // empty'
    return 0
}

# --- Funciones de interacción con Zabbix API (history_push, get_itemid) ---

get_itemid() {
    local url_fe="$1"
    local token="$2"
    local host_host="$3"
    local item_key="$4"

    # Validación de params de entrada
    if [[ -z "$url_fe" || -z "$token" || -z "$host_host" || -z "$item_key" ]]; then
        echo "Error: faltan parámetros en get_itemid" >&2
        return 1
    fi

    curl -k -w "\n" -s -X POST \
         -H "Content-Type: application/json-rpc" \
         -H "Authorization: Bearer ${token}" \
         -d '{
             "jsonrpc": "2.0",
             "method": "item.get",
             "params": {
                 "host": "'"${host_host}"'",
                 "filter": {
                     "key_": "'"${item_key}"'"
                 },
                 "output": ["itemid"]
             },
             "id": 1
         }' \
         "${url_fe}" | jq -r '.result[]|.itemid'
}

history_push() {
    local url_fe="$1"
    local token="$2"
    local item_id="$3"
    local value_to_push="$4"

    # Validación de params de entrada
    if [[ -z "$url_fe" || -z "$token" || -z "$item_id" || -z "$value_to_push" ]]; then
        echo "Error: faltan parámetros en history_push" >&2
        return 1
    fi

    # Construimos el request de history.push de forma segura,
    # para evitar romper con la estructura JSON del request al ingresar un $value que sea JSON
    local json_body
    json_body=$(jq -n --arg itemid "$item_id" --arg value "$value_to_push" '
        {
            jsonrpc: "2.0",
            method: "history.push",
            params: {
                itemid: $itemid,
                value: $value
            },
            id: 1
        }')

    local response
    response=$(curl -k -w "\n" -s -X POST \
         -H "Content-Type: application/json-rpc" \
         -H "Authorization: Bearer ${token}" \
         -d "$json_body" \
         "${url_fe}")

    local curl_exit=$?
    if [[ $curl_exit -ne 0 ]]; then
        echo "Error: fallo en la conexión HTTP" >&2
        return 1
    fi

    # Verificar si Zabbix devolvió un error
    # jq -e '.error' retorna un exit_status = 1 si no encontró .error
    if echo "$response" | jq -e '.error' >/dev/null 2>&1; then
        echo "Error de Zabbix: $(echo "$response" | jq -r '.error.data // .error.message // "desconocido"')" >&2
        return 1
    fi

    # Imprimimos el result, pero si no existe no imprimimos nada, no da error
    echo "$response" | jq -r '.result // empty'
    return 0
}

# --- Funciones de manejo de resultados ---

# Función para enviar mensajes (y errores) por history.push via API y stdout
send_result() {
    local url_fe="$1"      # La URL del Zabbix Frontend
    local token="$2"       # API Token de Zabbix
    local item_id="$3"     # ID del item en el cual vamos a loguear los resultados de la operacion
    local mode="$4"        # update_maintenance, display_maintenance, create_maintenance, etc.
    local status="$5"      # success, error
    local message="$6"     # puede ser JSON o texto
    local host_host="$7"   # Nombre del host donde se van a cargar los resultados de la operacion
    local item_key="$8"    # Key del item donde se van a cargar los resultados de la operacion

    # Determinar si 'message' es un JSON válido
    if echo "$message" | jq empty 2>/dev/null; then
        # Es JSON válido: usamos --slurpfile para insertarlo como objeto
        local full_msg
        full_msg=$(jq -n --arg mode_val "$mode" --arg status_val "$status" --slurpfile msg_val <(echo "$message") \
            '{mode: $mode_val, status: $status_val, message: $msg_val[0]}')
    else
        # No es JSON: escapamos como string
        local full_msg
        full_msg=$(jq -n --arg mode_val "$mode" --arg status_val "$status" --arg msg_val "$message" \
            '{mode: $mode_val, status: $status_val, message: $msg_val}')
    fi

    # Enviar a Zabbix
    if history_push "$url_fe" "$token" "$item_id" "$full_msg" >/dev/null 2>&1; then
        echo "✅ Enviado a Zabbix: $mode - $status"
        echo "📄 Host: $host_host - Item Key: $item_key"
    else
        echo "❌ Fallo al enviar a Zabbix: $mode - $status" >&2
    fi

    # Mostramos en stdout
    echo "$full_msg" | jq -c ''
}

# --- Funciones auxiliares de script ---

# Función para construir el JSON de entrada para el handler JavaScript
# Acepta el 'action' y los parámetros específicos
build_input_json_for_action() {
    local action="$1"
    # Se esperan más parámetros según la acción
    # Este es un ejemplo genérico, se puede especializar por acción
    # Usamos variables globales definidas en cada cmd_*
    case "$action" in
        create)
            # Usar las variables CREATE_*
            jq -n --arg url "$ZBX_URL" --arg token "$ZBX_APITOKEN" --arg act "$action" \
               --arg name "$CREATE_NAME" --argjson since "$CREATE_ACTIVE_SINCE_PARSED" --argjson till "$CREATE_ACTIVE_TILL_PARSED" \
               --argjson type "$CREATE_TYPE" --argjson start_date "$CREATE_STARTDATE_PARSED" --argjson period "$CREATE_PERIOD_SECONDS" \
               --arg hostnames "$CREATE_HOSTNAMES" --arg groupnames "$CREATE_GROUPNAMES" \
               '{
                   zbx_url: $url,
                   zbx_apitoken: $token,
                   action: $act,
                   maintenance_name: $name,
                   maintenance_active_since: $since,
                   maintenance_active_till: $till,
                   maintenance_type: $type,
                   timeperiod_startdate: $start_date,
                   timeperiod_period: $period,
                   hostnames: $hostnames,
                   groupnames: $groupnames
               }'
            ;;
        update)
            # Usar las variables UPDATE_*
            jq -n --arg url "$ZBX_URL" --arg token "$ZBX_APITOKEN" --arg act "$action" \
               --arg name "$UPDATE_NAME" --argjson start_date "$UPDATE_STARTDATE_PARSED" --argjson period "$UPDATE_PERIOD_SECONDS" \
               --arg hostnames "$UPDATE_HOSTNAMES" --arg groupnames "$UPDATE_GROUPNAMES" --arg sector "$UPDATE_SECTOR" \
               '{
                   zbx_url: $url,
                   zbx_apitoken: $token,
                   action: $act,
                   maintenance_name: $name,
                   timeperiod_startdate: $start_date,
                   timeperiod_period: $period,
                   hostnames: $hostnames,
                   groupnames: $groupnames,
                   sector: $sector
               }'
            ;;
        # Otros casos como delete, list...
        *)
            echo '{}' # JSON vacío por defecto si la acción no está implementada
            ;;
    esac
}


# --- Funciones de ayuda ---

# Función: mostrar ayuda general
show_help_general() {
    cat << 'EOF'
Uso: run_maintenance.sh <comando> [OPCIONES]

Herramienta para gestionar mantenimientos en Zabbix.

Comandos:
    create      Crea un nuevo mantenimiento.
    update      Actualiza un mantenimiento existente.
    delete      Elimina un mantenimiento existente.
    list        Lista mantenimientos existentes.

Use 'run_maintenance.sh <comando> --help' para ver opciones específicas de cada comando.
EOF
}

# Ayuda específica para cada subcomando
show_help_create() {
    cat << 'EOF'
Uso: run_maintenance.sh create [OPCIONES]

Crea un nuevo mantenimiento en Zabbix.

Opciones:
    -n, --name NAME                 Nombre del nuevo mantenimiento (requerido).
    --active-since TIMESTAMP        Timestamp Unix de inicio del mantenimiento (requerido).
    --active-till TIMESTAMP         Timestamp Unix de fin del mantenimiento (requerido).
    --type TYPE                     Tipo de mantenimiento (0: Normal, 1: No Data). Por defecto 0.
    --period PERIOD                 Duración del período de mantenimiento (ej: 2h, 1d). Requerido.
    --startdate STARTDATE           Fecha/hora de inicio del primer período (timestamp o formato yyyy-mm-dd hh:mm:ss). Por defecto, ahora.
    -H, --hostnames LIST            Lista de hosts separados por comas.
    -G, --groupnames LIST           Lista de grupos separados por comas.

Ejemplo:
    ./run_maintenance.sh create \
        --name "Mantenimiento de Prueba" \
        --active-since 1704067200 \
        --active-till 1704153600 \
        --period 2h \
        --hostnames "Serv1, Serv2"
EOF
}

show_help_update() {
    cat << 'EOF'
Uso: run_maintenance.sh update [OPCIONES]

Actualiza un mantenimiento existente en Zabbix.

Opciones:
    -n, --name NAME                 Nombre del mantenimiento a actualizar (requerido).
    --period PERIOD                 Nueva duración del período de mantenimiento (ej: 2h, 1d).
    --startdate STARTDATE           Nueva fecha/hora de inicio del período (timestamp o formato yyyy-mm-dd hh:mm:ss).
    -H, --hostnames LIST            Nueva lista de hosts separados por comas.
    -G, --groupnames LIST           Nueva lista de grupos separados por comas.
    -S, --sector NAME               Sector responsable (requerido para registro en Zabbix).

Ejemplo:
    ./run_maintenance.sh update \
        --name "Mantenimiento de Prueba" \
        --period 4h \
        --hostnames "Serv1, Serv3"
EOF
}

show_help_delete() {
    cat << 'EOF'
Uso: run_maintenance.sh delete [OPCIONES]

Elimina un mantenimiento existente en Zabbix.

Opciones:
    -n, --name NAME                 Nombre del mantenimiento a eliminar (requerido).

Ejemplo:
    ./run_maintenance.sh delete --name "Mantenimiento de Prueba"
EOF
}

show_help_list() {
    cat << 'EOF'
Uso: run_maintenance.sh list [OPCIONES]

Lista mantenimientos en Zabbix.

Opciones:
    -f, --filter FILTER             Filtro opcional para la búsqueda (nombre, etc.).

Ejemplo:
    ./run_maintenance.sh list --filter "Prod"
EOF
}

# --- Subcomandos ---

cmd_create() {
    # Parseo específico para create (usando $@)
    while [[ $# -gt 0 ]]; do
        case $1 in
            -n|--name)
                if [[ -z "$2" ]]; then echo "Error: --name requiere un valor." >&2; exit 1; fi
                CREATE_NAME="$2"; shift 2 ;;
            --active-since)
                if [[ -z "$2" ]]; then echo "Error: --active-since requiere un valor." >&2; exit 1; fi
                CREATE_ACTIVE_SINCE="$2"; shift 2 ;;
            --active-till)
                if [[ -z "$2" ]]; then echo "Error: --active-till requiere un valor." >&2; exit 1; fi
                CREATE_ACTIVE_TILL="$2"; shift 2 ;;
            --type)
                if [[ -z "$2" ]]; then echo "Error: --type requiere un valor." >&2; exit 1; fi
                CREATE_TYPE="$2"; shift 2 ;;
            --period)
                if [[ -z "$2" ]]; then echo "Error: --period requiere un valor." >&2; exit 1; fi
                CREATE_PERIOD="$2"; shift 2 ;;
            --startdate)
                if [[ -z "$2" ]]; then echo "Error: --startdate requiere un valor." >&2; exit 1; fi
                CREATE_STARTDATE="$2"; shift 2 ;;
            -H|--hostnames)
                if [[ -z "$2" ]]; then echo "Error: --hostnames requiere un valor." >&2; exit 1; fi
                CREATE_HOSTNAMES="$2"; shift 2 ;;
            -G|--groupnames)
                if [[ -z "$2" ]]; then echo "Error: --groupnames requiere un valor." >&2; exit 1; fi
                CREATE_GROUPNAMES="$2"; shift 2 ;;
            --help|-h)
                show_help_create; exit 0 ;;
            *)
                echo "Error: opción desconocida para create: $1" >&2; show_help_create; exit 1 ;;
        esac
    done

    # Validación de parámetros requeridos para create
    if [[ -z "$CREATE_NAME" || -z "$CREATE_ACTIVE_SINCE" || -z "$CREATE_ACTIVE_TILL" || -z "$CREATE_PERIOD" ]]; then
        echo "Error: Parámetros requeridos faltantes para create." >&2
        show_help_create
        exit 1
    fi

    # Parseo de valores (timestamps, periodos)
    CREATE_ACTIVE_SINCE_PARSED=$(parse_datetime_to_timestamp "$CREATE_ACTIVE_SINCE") || exit 1
    CREATE_ACTIVE_TILL_PARSED=$(parse_datetime_to_timestamp "$CREATE_ACTIVE_TILL") || exit 1
    CREATE_PERIOD_SECONDS=$(parse_time_to_seconds "$CREATE_PERIOD") || exit 1
    if [[ -n "$CREATE_STARTDATE" ]]; then
        CREATE_STARTDATE_PARSED=$(parse_datetime_to_timestamp "$CREATE_STARTDATE") || exit 1
    else
        CREATE_STARTDATE_PARSED=$(date +%s)
    fi
    if [[ -z "$CREATE_TYPE" ]]; then CREATE_TYPE=0; fi # Valor por defecto

    # Construimos el JSON de entrada para el handler, incluyendo la acción
    local action_json
    action_json=$(build_input_json_for_action "create")

    # Llamamos al handler JavaScript con el nuevo JSON
    local rsp_msg
    rsp_msg=$(zabbix_js -s "$MAINTENANCE_HANDLER_JS" -p "$action_json")
    local exit_code=$?

    if [ $exit_code -ne 0 ] || echo "$rsp_msg" | grep -q "error\|Problema"; then
        echo "Error: Falló la creación del mantenimiento." >&2
        echo "$rsp_msg" >&2
        exit 1
    else
        echo "Mantenimiento creado exitosamente:"
        echo "$rsp_msg"
        # Opcional: enviar resultado a Zabbix (requiere item_id y sector)
        # local HOST_LOG="Registros de Mantenimientos"
        # local KEY_SECTOR="mantenimientos.${SECTOR_DEFAULT_IF_ANY}" # Deberías pasar el sector o tener uno por defecto si aplica
        # local item_id=$(get_itemid "$ZBX_URL" "$ZBX_APITOKEN" "$HOST_LOG" "$KEY_SECTOR")
        # send_result "$ZBX_URL" "$ZBX_APITOKEN" "$item_id" "create_maintenance" "success" "$rsp_msg" "$HOST_LOG" "$KEY_SECTOR"
    fi
}

cmd_update() {
    # Parseo específico para update
    while [[ $# -gt 0 ]]; do
        case $1 in
            -n|--name)
                if [[ -z "$2" ]]; then echo "Error: --name requiere un valor." >&2; exit 1; fi
                UPDATE_NAME="$2"; shift 2 ;;
            --period)
                if [[ -z "$2" ]]; then echo "Error: --period requiere un valor." >&2; exit 1; fi
                UPDATE_PERIOD="$2"; shift 2 ;;
            --startdate)
                if [[ -z "$2" ]]; then echo "Error: --startdate requiere un valor." >&2; exit 1; fi
                UPDATE_STARTDATE="$2"; shift 2 ;;
            -H|--hostnames)
                if [[ -z "$2" ]]; then echo "Error: --hostnames requiere un valor." >&2; exit 1; fi
                UPDATE_HOSTNAMES="$2"; shift 2 ;;
            -G|--groupnames)
                if [[ -z "$2" ]]; then echo "Error: --groupnames requiere un valor." >&2; exit 1; fi
                UPDATE_GROUPNAMES="$2"; shift 2 ;;
            -S|--sector) # Este parámetro es para el registro en Zabbix
                if [[ -z "$2" ]]; then echo "Error: --sector requiere un valor." >&2; exit 1; fi
                UPDATE_SECTOR="$2"; shift 2 ;;
            --help|-h)
                show_help_update; exit 0 ;;
            *)
                echo "Error: opción desconocida para update: $1" >&2; show_help_update; exit 1 ;;
        esac
    done

    # Validación de parámetros requeridos para update
    if [[ -z "$UPDATE_NAME" ]]; then
        echo "Error: Parámetro requerido faltante para update: --name." >&2
        show_help_update
        exit 1
    fi

    # Parseo de valores (si se proporcionaron)
    local update_period_sec=""
    local update_startdate_ts=""
    if [[ -n "$UPDATE_PERIOD" ]]; then
        update_period_sec=$(parse_time_to_seconds "$UPDATE_PERIOD") || exit 1
    fi
    if [[ -n "$UPDATE_STARTDATE" ]]; then
        update_startdate_ts=$(parse_datetime_to_timestamp "$UPDATE_STARTDATE") || exit 1
    else
        update_startdate_ts=$(date +%s)
    fi
    # Asignamos a variables globales para el JSON
    UPDATE_PERIOD_SECONDS="$update_period_sec"
    UPDATE_STARTDATE_PARSED="$update_startdate_ts"

    # Construimos el JSON de entrada para el handler, incluyendo la acción
    local action_json
    action_json=$(build_input_json_for_action "update")

    # Llamamos al handler JavaScript con el nuevo JSON
    local rsp_msg
    rsp_msg=$(zabbix_js -s "$MAINTENANCE_HANDLER_JS" -p "$action_json")
    local exit_code=$?

    if [ $exit_code -ne 0 ] || echo "$rsp_msg" | grep -q "error\|Problema"; then
        echo "Error: Falló la actualización del mantenimiento." >&2
        echo "$rsp_msg" >&2
        exit 1
    else
        echo "Mantenimiento actualizado exitosamente:"
        echo "$rsp_msg"
        # Opcional: enviar resultado a Zabbix (esto podría repetirse con display)
        # Similar al create, necesitas el item_id y el sector.
        if [[ -n "$UPDATE_SECTOR" ]]; then
            local HOST_LOG="Registros de Mantenimientos"
            local KEY_SECTOR="mantenimientos.${UPDATE_SECTOR}"
            local item_id=$(get_itemid "$ZBX_URL" "$ZBX_APITOKEN" "$HOST_LOG" "$KEY_SECTOR")
            if [[ -n "$item_id" ]]; then
                send_result "$ZBX_URL" "$ZBX_APITOKEN" "$item_id" "update_maintenance" "success" "$rsp_msg" "$HOST_LOG" "$KEY_SECTOR"
            else
                echo "Advertencia: No se pudo obtener el itemid para registrar el resultado." >&2
            fi
        fi
    fi

    # Display opcional o requerido después de update (similar a como estaba antes)
    # Por ahora, lo hacemos siempre si se especificó un sector.
    if [[ -n "$UPDATE_SECTOR" ]]; then
        # Reutilizamos build_input_json_for_action para un modo "display"
        # Temporalmente creamos una función específica o reutilizamos update con action=display
        local display_json
        display_json=$(jq -n --arg url "$ZBX_URL" --arg token "$ZBX_APITOKEN" --arg act "display" --arg name "$UPDATE_NAME" \
            '{zbx_url: $url, zbx_apitoken: $token, action: $act, maintenance_name: $name}')

        local disp_msg
        disp_msg=$(zabbix_js -s "$MAINTENANCE_HANDLER_JS" -p "$display_json")
        local disp_exit_code=$?

        if [ $disp_exit_code -ne 0 ] || echo "$disp_msg" | grep -q "error\|Problema\|null"; then
            echo "Advertencia: No se pudo obtener el estado actual del mantenimiento." >&2
            echo "$disp_msg" >&2
        else
            echo "Estado actual del mantenimiento:"
            echo "$disp_msg"
            # Enviar resultado a Zabbix
            if [[ -n "$item_id" ]]; then # Reutilizamos item_id obtenido antes
                send_result "$ZBX_URL" "$ZBX_APITOKEN" "$item_id" "display_maintenance" "success" "$disp_msg" "$HOST_LOG" "$KEY_SECTOR"
            else
                echo "Advertencia: No se pudo obtener el itemid para registrar el resultado de display." >&2
            fi
        fi
    fi
}

cmd_delete() {
    # Parseo específico para delete
    while [[ $# -gt 0 ]]; do
        case $1 in
            -n|--name)
                if [[ -z "$2" ]]; then echo "Error: --name requiere un valor." >&2; exit 1; fi
                DELETE_NAME="$2"; shift 2 ;;
            --help|-h)
                show_help_delete; exit 0 ;;
            *)
                echo "Error: opción desconocida para delete: $1" >&2; show_help_delete; exit 1 ;;
        esac
    done

    # Validación de parámetros requeridos para delete
    if [[ -z "$DELETE_NAME" ]]; then
        echo "Error: Parámetro requerido faltante para delete: --name." >&2
        show_help_delete
        exit 1
    fi

    echo "Eliminar mantenimiento: $DELETE_NAME"
    # Lógica de delete (requiere nueva función JS y adaptación del handler)
    # local action_json = ...
    # zabbix_js -s ... -p "$action_json"
    echo "Funcionalidad de borrado no implementada aún." >&2
    exit 1
}

cmd_list() {
    # Parseo específico para list
    while [[ $# -gt 0 ]]; do
        case $1 in
            -f|--filter)
                if [[ -z "$2" ]]; then echo "Error: --filter requiere un valor." >&2; exit 1; fi
                LIST_FILTER="$2"; shift 2 ;;
            --help|-h)
                show_help_list; exit 0 ;;
            *)
                echo "Error: opción desconocida para list: $1" >&2; show_help_list; exit 1 ;;
        esac
    done

    echo "Listar mantenimientos con filtro: $LIST_FILTER"
    # Lógica de list (requiere nueva función JS y adaptación del handler)
    # local action_json = ...
    # zabbix_js -s ... -p "$action_json"
    echo "Funcionalidad de listado no implementada aún." >&2
    exit 1
}

# =============================================================================
# 3. === INICIALIZACIÓN DEL SCRIPT ===
# =============================================================================

set -e
set -u

# Validar dependencias
command -v zabbix_js >/dev/null 2>&1 || { echo "Error: zabbix_js no encontrado." >&2; exit 1; }
command -v zabbix_sender >/dev/null 2>&1 || { echo "Error: zabbix_sender no encontrado." >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "Error: jq no encontrado." >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "Error: curl no encontrado." >&2; exit 1; }

# Detectar raíz del proyecto usando la función
PROJECT_ROOT=$(find_project_root)

# Ruta por defecto para el archivo de configuración (relativa a la raíz)
DEFAULT_CONFIG_FILE="${PROJECT_ROOT}/config/default_params.conf"

# Definir rutas basadas en la raíz del proyecto
MAINTENANCE_HANDLER_JS="${PROJECT_ROOT}/src/maintenance_handler.js"

# Validar existencia de archivos críticos
if [ ! -f "$MAINTENANCE_HANDLER_JS" ]; then
    echo "Error: Archivo de handler no encontrado: $MAINTENANCE_HANDLER_JS" >&2
    exit 1
fi

# =============================================================================
# 4. === PARSING DE ARGUMENTOS GLOBAL (autenticación, config, subcomando) ===
# =============================================================================

# Parseo de argumentos globales (antes de subcomandos)
while [[ $# -gt 0 ]]; do
    case $1 in
        -c|--config)
            if [[ -z "$2" ]]; then echo "Error: --config requiere un valor." >&2; exit 1; fi
            CONFIG_FILE="$2"; shift 2 ;;
        -u|--zbx-url)
            if [[ -z "$2" ]]; then echo "Error: --zbx-url requiere un valor." >&2; exit 1; fi
            RAW_ZBX_URL="$2"; shift 2 ;;
        -U|--zbx-user)
            if [[ -z "$2" ]]; then echo "Error: --zbx-user requiere un valor." >&2; exit 1; fi
            RAW_ZBX_USER="$2"; shift 2 ;;
        -P|--zbx-password)
            if [[ -z "$2" ]]; then echo "Error: --zbx-password requiere un valor." >&2; exit 1; fi
            RAW_ZBX_PASSWORD="$2"; shift 2 ;;
        -t|--zbx-apitoken)
            if [[ -z "$2" ]]; then echo "Error: --zbx-apitoken requiere un valor." >&2; exit 1; fi
            RAW_ZBX_APITOKEN="$2"; shift 2 ;;
        --help|-h)
            show_help_general; exit 0 ;;
        create|update|delete|list) # Identificamos el subcomando
            COMMAND="$1"
            shift
            break
            ;;
        *)
            echo "Error: opción desconocida: $1" >&2; show_help_general; exit 1 ;;
    esac
done

# Si no se especificó subcomando
if [[ -z "$COMMAND" ]]; then
    echo "Error: No se especificó un subcomando." >&2
    show_help_general
    exit 1
fi

# Definir CONFIG_FILE definitivo si no se pasó --config
if [[ -z "$CONFIG_FILE" ]]; then
    CONFIG_FILE="$DEFAULT_CONFIG_FILE"
fi

# Cargar configuración *antes* de la autenticación
if [ -f "$CONFIG_FILE" ]; then
    echo "Cargando configuración desde: $CONFIG_FILE" >&2
    if [[ -r "$CONFIG_FILE" && -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE"
    else
        echo "Error: El archivo de configuración no es un archivo regular o no es legible: $CONFIG_FILE" >&2
        exit 1
    fi
else
    echo "Advertencia: Archivo de configuración no encontrado: $CONFIG_FILE" >&2
    echo "Se usarán los valores proporcionados por banderas o vacíos." >&2
fi

# Aplicar valores de banderas (si existen) para sobrescribir la configuración
if [[ -n "$RAW_ZBX_URL" ]]; then ZBX_URL="$RAW_ZBX_URL"; fi
if [[ -n "$RAW_ZBX_USER" ]]; then ZBX_USER="$RAW_ZBX_USER"; fi
if [[ -n "$RAW_ZBX_PASSWORD" ]]; then ZBX_PASSWORD="$RAW_ZBX_PASSWORD"; fi
if [[ -n "$RAW_ZBX_APITOKEN" ]]; then ZBX_APITOKEN="$RAW_ZBX_APITOKEN"; fi

# --- Inicio de lógica de autenticación ---
SESSION_TOKEN=""
if [[ -n "$ZBX_USER" && -n "$ZBX_PASSWORD" ]]; then
    echo "Iniciando sesión en Zabbix como '$ZBX_USER'..." >&2
    SESSION_TOKEN=$(zbx_login "$ZBX_URL" "$ZBX_USER" "$ZBX_PASSWORD")
    if [[ $? -ne 0 || -z "$SESSION_TOKEN" ]]; then
        echo "Error fatal: No se pudo iniciar sesión." >&2
        exit 1
    fi
    # Usamos el token de sesión como si fuera un API token
    ZBX_APITOKEN="$SESSION_TOKEN"
    # Limpiar las credenciales sensibles de la memoria (opcional pero recomendado)
    unset ZBX_PASSWORD
fi

# Validación de campos obligatorios comunes (después de cargar la configuración, aplicar flags y autenticación)
if [[ -z "$ZBX_URL" || -z "$ZBX_APITOKEN" ]]; then
    echo "Error: Faltan parámetros obligatorios comunes (zbx_url, zbx_apitoken)." >&2
    echo "Use --help para ver el uso general." >&2
    exit 1
fi

# =============================================================================
# 5. === EJECUCIÓN DEL SUBCOMANDO ===
# =============================================================================

case "$COMMAND" in
    create)  cmd_create "$@" ;;
    update)  cmd_update "$@" ;;
    delete)  cmd_delete "$@" ;;
    list)    cmd_list "$@" ;;
    *)
        echo "Error: Subcomando desconocido: $COMMAND" >&2
        show_help_general
        exit 1
        ;;
esac

# =============================================================================
# 6. === FINALIZACIÓN (logout, etc.) ===
# =============================================================================

# Si se inició sesión, intentar cerrarla
if [[ -n "$SESSION_TOKEN" ]]; then
    echo "Cerrando sesión en Zabbix..." >&2
    zbx_logout "$ZBX_URL" "$SESSION_TOKEN" >/dev/null 2>&1 || true # Ignorar error de logout
fi

exit 0
