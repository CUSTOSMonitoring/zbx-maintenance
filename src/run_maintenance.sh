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
PREFIX_MAINTENANCE_NAME="[Web Mantenimientos] " #Prefijo que tendrán todos los mantenimientos gestionados por esta solución

# Variables temporales para parseo de argumentos globales (antes de subcomandos)
RAW_ZBX_URL=""
RAW_ZBX_USER=""
RAW_ZBX_PASSWORD=""
RAW_ZBX_APITOKEN=""
RAW_PREFIX_MAINTENANCE_NAME=""

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
CREATE_DESCRIPTION=""
CREATE_SECTOR="" # Necesario para el registro en Zabbix
# UPDATE
UPDATE_NAME=""
UPDATE_PERIOD=""
UPDATE_STARTDATE=""
UPDATE_ACTIVE_SINCE=""
UPDATE_ACTIVE_TILL=""
UPDATE_TYPE=""
UPDATE_HOSTNAMES=""
UPDATE_GROUPNAMES=""
UPDATE_DESCRIPTION=""
UPDATE_SECTOR="" # Necesario para el registro en Zabbix
# DELETE
DELETE_NAME=""
DELETE_SECTOR=""
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
                password: $pass,
                userData: true
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
    # Usamos variables globales definidas en cada cmd_*
    case "$action" in
        create)
            # Usar las variables CREATE_*
            # Inicializamos variables para el JSON con valores vacíos o nulos si no se definieron
            local period_json="null"
            local startdate_json="null"
            local since_json="null"
            local till_json="null"
            local type_json="null"
            # NO inicializamos desc_json con "null"

            # Solo incluimos en el JSON los valores que fueron realmente especificados
            if [[ -n "$CREATE_PERIOD_SECONDS" ]]; then period_json="$CREATE_PERIOD_SECONDS"; fi
            if [[ -n "$CREATE_STARTDATE_PARSED" ]]; then startdate_json="$CREATE_STARTDATE_PARSED"; fi
            if [[ -n "$CREATE_ACTIVE_SINCE_PARSED" ]]; then since_json="$CREATE_ACTIVE_SINCE_PARSED"; fi
            if [[ -n "$CREATE_ACTIVE_TILL_PARSED" ]]; then till_json="$CREATE_ACTIVE_TILL_PARSED"; fi
            if [[ -n "$CREATE_TYPE" ]]; then type_json="$CREATE_TYPE"; fi
            # No procesamos CREATE_DESCRIPTION aquí directamente en las variables

            # Construimos el objeto JSON condicionalmente
            # Usamos --arg para cada valor que sí tiene
            local jq_args=(--arg url "$ZBX_URL" --arg token "$ZBX_APITOKEN" --arg act "$action" --arg name "$CREATE_NAME")
            jq_args+=(--argjson since_val "$since_json" --argjson till_val "$till_json" --argjson type_val "$type_json")
            jq_args+=(--argjson period_val "$period_json" --argjson start_date_val "$startdate_json")
            jq_args+=(--arg hostnames "$CREATE_HOSTNAMES" --arg groupnames "$CREATE_GROUPNAMES")

            # Añadimos --arg para description solo si CREATE_DESCRIPTION no está vacío
            if [[ -n "$CREATE_DESCRIPTION" ]]; then
                jq_args+=(--arg desc_val "$CREATE_DESCRIPTION") # Pasamos la cadena sin procesar
                # Construimos el objeto JSON incluyendo description
                jq -n "${jq_args[@]}" '
                    {
                        zbx_url: $url,
                        zbx_apitoken: $token,
                        action: $act,
                        maintenance_name: $name,
                        maintenance_active_since: $since_val,
                        maintenance_active_till: $till_val,
                        maintenance_type: $type_val,
                        timeperiod_period: $period_val,
                        timeperiod_startdate: $start_date_val,
                        maintenance_description: $desc_val,
                        hostnames: $hostnames,
                        groupnames: $groupnames
                    }'
            else
                # Construimos el objeto JSON SIN el campo description
                jq -n "${jq_args[@]}" '
                    {
                        zbx_url: $url,
                        zbx_apitoken: $token,
                        action: $act,
                        maintenance_name: $name,
                        maintenance_active_since: $since_val,
                        maintenance_active_till: $till_val,
                        maintenance_type: $type_val,
                        timeperiod_period: $period_val,
                        timeperiod_startdate: $start_date_val,
                        hostnames: $hostnames,
                        groupnames: $groupnames
                    }'
            fi
            ;;
        update)
            # Argumentos base que SIEMPRE van
            local jq_args=(
                --arg url "$ZBX_URL"
                --arg token "$ZBX_APITOKEN"
                --arg act "$action"
                --arg name "$UPDATE_NAME"
                --arg hostnames "$UPDATE_HOSTNAMES"
                --arg groupnames "$UPDATE_GROUPNAMES"
                --arg sector_val "$UPDATE_SECTOR"
            )

            # Campos que PUEDEN ir: SIEMPRE los pasamos, con null si no tienen valor
            if [[ -n "$UPDATE_PERIOD_SECONDS" ]]; then
                jq_args+=(--argjson period_val "$UPDATE_PERIOD_SECONDS")
            else
                jq_args+=(--argjson period_val null)
            fi
            if [[ -n "$UPDATE_STARTDATE_PARSED" ]]; then
                jq_args+=(--argjson start_date_val "$UPDATE_STARTDATE_PARSED")
            else
                jq_args+=(--argjson start_date_val null)
            fi
            if [[ -n "$UPDATE_ACTIVE_SINCE_PARSED" ]]; then
                jq_args+=(--argjson since_val "$UPDATE_ACTIVE_SINCE_PARSED")
            else
                jq_args+=(--argjson since_val null)
            fi
            if [[ -n "$UPDATE_ACTIVE_TILL_PARSED" ]]; then
                jq_args+=(--argjson till_val "$UPDATE_ACTIVE_TILL_PARSED")
            else
                jq_args+=(--argjson till_val null)
            fi
            if [[ -n "$UPDATE_TYPE" ]]; then
                jq_args+=(--argjson type_val "$UPDATE_TYPE")
            else
                jq_args+=(--argjson type_val null)
            fi
            # IMPORTANTE: Para description, usar --argjson con null, NO --arg con "null"
            if [[ -n "$UPDATE_DESCRIPTION" ]]; then
                jq_args+=(--arg desc_val "$UPDATE_DESCRIPTION")
            else
                jq_args+=(--argjson desc_val null)  # <-- JSON null, no string "null"
            fi

            # Filtro de jq: objeto base + campos opcionales condicionales
            local jq_filter='
            {
                zbx_url: $url,
                zbx_apitoken: $token,
                action: $act,
                maintenance_name: $name,
                timeperiod_period: $period_val,
                timeperiod_startdate: $start_date_val,
                hostnames: $hostnames,
                groupnames: $groupnames,
                sector: $sector_val
            }
            | . as $base
            | [
                if $since_val != null then {maintenance_active_since: $since_val} else {} end,
                if $till_val != null then {maintenance_active_till: $till_val} else {} end,
                if $type_val != null then {maintenance_type: $type_val} else {} end,
                if $desc_val != null then {maintenance_description: $desc_val} else {} end
            ]
            | add as $optional
            | $base + $optional
            '

            jq -n "${jq_args[@]}" "$jq_filter"
            ;;
        delete)
            # Argumentos base para delete
            local jq_args=(
                --arg url "$ZBX_URL"
                --arg token "$ZBX_APITOKEN"
                --arg act "delete"
                --arg name "${DELETE_NAME}"
            )

            # Construimos el objeto JSON para delete
            jq -n "${jq_args[@]}" '
            {
                zbx_url: $url,
                zbx_apitoken: $token,
                action: $act,
                maintenance_name: $name
            }'
            ;;
        *)
            echo '{}' # JSON vacío por defecto si la acción no está implementada
            ;;
    esac
}

# Función para ejecutar el modo 'display' y reportar resultados a stdout y Zabbix
# Recibe el nombre del mantenimiento y el sector.
execute_display_and_report() {
    local disp_maintenance_name="$1"
    local disp_sector="$2"

    if [[ -z "$disp_maintenance_name" || -z "$disp_sector" ]]; then
        echo "Error: execute_display_and_report requiere 'maintenance_name' y 'sector'." >&2
        return 1
    fi

    # Construimos el JSON de entrada para el handler, en modo 'display'
    # Incluimos el username si está disponible
    local display_json
    if [[ -n "$SESSION_USERNAME" ]]; then
        display_json=$(jq -n --arg url "$ZBX_URL" --arg token "$ZBX_APITOKEN" --arg act "display" --arg name "$disp_maintenance_name" --arg username "$SESSION_USERNAME" \
            '{zbx_url: $url, zbx_apitoken: $token, action: $act, maintenance_name: $name, username: $username}')
    else
        display_json=$(jq -n --arg url "$ZBX_URL" --arg token "$ZBX_APITOKEN" --arg act "display" --arg name "$disp_maintenance_name" \
            '{zbx_url: $url, zbx_apitoken: $token, action: $act, maintenance_name: $name}')
    fi

    local disp_msg
    disp_msg=$(zabbix_js -s "$MAINTENANCE_HANDLER_JS" -p "$display_json")
    local disp_exit_code=$?

    if [ $disp_exit_code -ne 0 ] || echo "$disp_msg" | grep -q "error\|Problema\|null"; then
        echo "Advertencia: No se pudo obtener el estado actual del mantenimiento '$disp_maintenance_name'." >&2
        echo "$disp_msg" >&2
        return 1 # O 0, dependiendo si quieres que un fallo en display detenga el flujo principal
    else
        echo "Estado actual del mantenimiento '$disp_maintenance_name':"
        echo "$disp_msg"

        # Enviar resultado a Zabbix
        local HOST_LOG="Registros de Mantenimientos"
        local KEY_SECTOR="mantenimientos.${disp_sector}"
        local item_id
        item_id=$(get_itemid "$ZBX_URL" "$ZBX_APITOKEN" "$HOST_LOG" "$KEY_SECTOR")
        if [[ -n "$item_id" ]]; then
            send_result "$ZBX_URL" "$ZBX_APITOKEN" "$item_id" "display_maintenance" "success" "$disp_msg" "$HOST_LOG" "$KEY_SECTOR"
        else
            echo "Advertencia: No se pudo obtener el itemid para registrar el resultado de display del mantenimiento '$disp_maintenance_name'." >&2
            return 1 # O 0, PENDIENTE: evaluar que tan critico puede ser esto
        fi
    fi
    return 0
}

# Recibe el tipo de acción, el JSON de entrada para zabbix_js y el sector para reportar a Zabbix.
execute_action_and_report() {
    local action_type="$1" # "create", "update" o "delete"
    local action_json="$2"
    local action_sector="$3" # Puede ser vacío si no se debe reportar a Zabbix

    # Validación básica
    if [[ -z "$action_type" || -z "$action_json" ]]; then
        echo "Error: execute_action_and_report requiere 'action_type' y 'action_json'." >&2
        return 1
    fi

    # Llamamos al handler JavaScript con el JSON de entrada
    local rsp_msg
    rsp_msg=$(zabbix_js -s "$MAINTENANCE_HANDLER_JS" -p "$action_json")
    local exit_code=$?

    # Determinar si hubo error basado en el código de salida o contenido del mensaje
    local has_error=0
    if [ $exit_code -ne 0 ] || echo "$rsp_msg" | grep -q "error\|Problema"; then
        has_error=1
    fi

    # Preparar mensajes y determinar status para Zabbix
    local user_message
    local zbx_mode
    local zbx_status
    if [ $has_error -eq 0 ]; then
        case "$action_type" in
            create)
                user_message="Mantenimiento creado exitosamente:"
                ;;
            update)
                user_message="Mantenimiento actualizado exitosamente:"
                ;;
            delete)
                user_message="Mantenimiento eliminado exitosamente:"
                ;;
            *)
                user_message="Resultado de la operación ($action_type):"
                ;;
        esac
        zbx_mode="${action_type}_maintenance"
        zbx_status="success"
    else
        case "$action_type" in
            create)
                user_message="Error: Falló la creación del mantenimiento."
                ;;
            update)
                user_message="Error: Falló la actualización del mantenimiento."
                ;;
            delete)
                user_message="Error: Falló la eliminación del mantenimiento."
                ;;
            *)
                user_message="Error: Falló la operación ($action_type)."
                ;;
        esac
        zbx_mode="${action_type}_maintenance"
        zbx_status="error"
    fi

    local enriched_msg="$rsp_msg"
    if [[ -n "$SESSION_USERNAME" ]]; then
        # Usamos jq para agregar los campos al JSON, manejando tanto objetos como strings
        if echo "$rsp_msg" | jq empty 2>/dev/null; then
            # rsp_msg es JSON válido, lo enriquecemos
            enriched_msg=$(echo "$rsp_msg" | jq --arg by "$SESSION_USERNAME" --argjson at "$(date "+%F %T")" \
                '. + {performed_by: $by, performed_at: $at}')
        else
            # rsp_msg no es JSON (ej: mensaje de error plano), lo convertimos a objeto y enriquecemos
            enriched_msg=$(jq -n --arg msg "$rsp_msg" --arg by "$SESSION_USERNAME" --argjson at "$(date "+%F %T")" \
                '{message: $msg, performed_by: $by, performed_at: $at}')
        fi
    fi

    # Imprimir resultado en stdout
    ###echo "$user_message" ##DEBUG
    ###echo "$enriched_msg"

    # Reportar a Zabbix si se proporcionó un sector
    if [[ -n "$action_sector" ]]; then
        local HOST_LOG="Registros de Mantenimientos"
        local KEY_SECTOR="mantenimientos.${action_sector}"
        local item_id
        item_id=$(get_itemid "$ZBX_URL" "$ZBX_APITOKEN" "$HOST_LOG" "$KEY_SECTOR")

        if [[ -n "$item_id" ]]; then
            send_result "$ZBX_URL" "$ZBX_APITOKEN" "$item_id" "$zbx_mode" "$zbx_status" "$enriched_msg" "$HOST_LOG" "$KEY_SECTOR"
        else
            echo "Advertencia: No se pudo obtener el itemid para registrar el resultado de $action_type en el sector '$action_sector'." >&2
            # Opcional: Retornar 1 aquí si decidimos que puede llegar a ser un error critico
            # return 1
        fi
    else
        # Si no se proporciona sector, no reportamos a Zabbix, pero la operación puede continuar
        echo "Info: No se especificó sector para reportar el resultado de $action_type a Zabbix." >&2
    fi

    # Si hubo error en la ejecución del handler, retornamos un código de error
    # para que la función llamadora pueda actuar en consecuencia (por ejemplo, salir del script).
    if [ $has_error -eq 1 ]; then
        return 1
    fi

    return 0
}

# --- Funciones de ayuda ---

# Función: mostrar ayuda general
show_help_general() {
    cat << 'EOF'
Uso: run_maintenance.sh [OPCIONES_GLOBALES] <comando> [OPCIONES_DEL_COMANDO]

Herramienta para gestionar mantenimientos en Zabbix.

Opciones globales:
    -u, --zbx-url URL               URL del API de Zabbix (ej: https://zabbix/api_jsonrpc.php)
    -U, --zbx-user USER             Usuario de Zabbix para autenticación por sesión.
    -P, --zbx-password PASS         Contraseña de Zabbix para autenticación por sesión.
    -t, --zbx-apitoken TOKEN        Token de API de Zabbix (alternativa a usuario/contraseña).
    -c, --config PATH               Ruta al archivo de configuración (por defecto: config/default_params.conf)
    -h, --help                      Muestra esta ayuda general y sale

Comandos:
    create      Crea un nuevo mantenimiento.
    update      Actualiza un mantenimiento existente.
    delete      Elimina un mantenimiento existente.
    list        Lista mantenimientos existentes gestionados por este proyecto (filtrados por prefijo).

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
    --active-since TIMESTAMP        Timestamp Unix de inicio del mantenimiento. Por defecto, ahora.
    --active-till TIMESTAMP         Timestamp Unix de fin del mantenimiento. Por defecto, ahora + 3 años.
    --type TYPE                     Tipo de mantenimiento (0: Normal, 1: No Data). Por defecto 0.
    --period PERIOD                 Duración del período de mantenimiento (ej: 2h, 1d). Requerido.
    --startdate STARTDATE           Fecha/hora de inicio del primer período (timestamp o formato yyyy-mm-dd hh:mm:ss). Por defecto, ahora.
    --description TEXT              Descripción del mantenimiento (opcional).
    -H, --hostnames LIST            Lista de hosts separados por comas.
    -G, --groupnames LIST           Lista de grupos separados por comas.
    -S, --sector NAME               Sector responsable (requerido para registro en Zabbix).

Ejemplo:
    ./run_maintenance.sh create \
        --name "Mantenimiento de Prueba" \
        --period 2h \
        --description "Mantenimiento programado para el grupo de Servicios" \
        --hostnames "Serv1, Serv2" \
        --sector "Servicios"
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
    --active-since TIMESTAMP        Nuevo timestamp Unix de inicio del mantenimiento (opcional).
    --active-till TIMESTAMP         Nuevo timestamp Unix de fin del mantenimiento (opcional).
    --type TYPE                     Nuevo tipo de mantenimiento (0: Normal, 1: No Data) (opcional).
    --description TEXT              Nueva descripción del mantenimiento (opcional).
    -H, --hostnames LIST            Nueva lista de hosts separados por comas.
    -G, --groupnames LIST           Nueva lista de grupos separados por comas.
    -S, --sector NAME               Sector responsable (requerido para registro en Zabbix).

Ejemplo:
    ./run_maintenance.sh update \
        --name "Mantenimiento de Prueba" \
        --period 4h \
        --description "Descripción actualizada del mantenimiento" \
        --hostnames "Serv1, Serv3" \
        --sector "Servicios"
EOF
}

show_help_delete() {
    cat << 'EOF'
Uso: run_maintenance.sh delete [OPCIONES]

Elimina un mantenimiento existente en Zabbix.

Opciones:
    -n, --name NAME                 Nombre del mantenimiento a eliminar (requerido).
    -S, --sector NAME               Sector responsable (requerido para registro en Zabbix).
    --help, -h                      Muestra esta ayuda y sale.

Ejemplo:
    ./run_maintenance.sh delete \
        --name "Mantenimiento de Prueba" \
        --sector "Servicios"

Nota:
    - El mantenimiento debe existir y ser gestionado por este proyecto (prefijo configurado).
    - La eliminación es permanente y no se puede deshacer.
EOF
}

show_help_list() {
    cat << 'EOF'
Uso: run_maintenance.sh list

Lista mantenimientos existentes gestionados por este proyecto (filtrados por prefijo).

Esta acción no requiere parámetros adicionales. El prefijo utilizado para filtrar
los mantenimientos se define en la configuración global del script o en el archivo de configuración.

Ejemplo:
    ./run_maintenance.sh list
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
                CREATE_ACTIVE_SINCE_RAW="$2"; shift 2 ;; # Almacenamos el valor raw
            --active-till)
                if [[ -z "$2" ]]; then echo "Error: --active-till requiere un valor." >&2; exit 1; fi
                CREATE_ACTIVE_TILL_RAW="$2"; shift 2 ;; # Almacenamos el valor raw
            --type)
                if [[ -z "$2" ]]; then echo "Error: --type requiere un valor." >&2; exit 1; fi
                CREATE_TYPE="$2"; shift 2 ;;
            --period)
                if [[ -z "$2" ]]; then echo "Error: --period requiere un valor." >&2; exit 1; fi
                CREATE_PERIOD="$2"; shift 2 ;;
            --startdate)
                if [[ -z "$2" ]]; then echo "Error: --startdate requiere un valor." >&2; exit 1; fi
                CREATE_STARTDATE="$2"; shift 2 ;;
            --description)
                if [[ -z "$2" ]]; then echo "Error: --description requiere un valor." >&2; exit 1; fi
                CREATE_DESCRIPTION="$2"; shift 2 ;;
            -H|--hostnames)
                if [[ -z "$2" ]]; then echo "Error: --hostnames requiere un valor." >&2; exit 1; fi
                CREATE_HOSTNAMES="$2"; shift 2 ;;
            -G|--groupnames)
                if [[ -z "$2" ]]; then echo "Error: --groupnames requiere un valor." >&2; exit 1; fi
                CREATE_GROUPNAMES="$2"; shift 2 ;;
            -S|--sector) # Este parámetro es para el registro en Zabbix
                if [[ -z "$2" ]]; then echo "Error: --sector requiere un valor." >&2; exit 1; fi
                CREATE_SECTOR="$2"; shift 2 ;;
            --help|-h)
                show_help_create; exit 0 ;;
            *)
                echo "Error: opción desconocida para create: $1" >&2; show_help_create; exit 1 ;;
        esac
    done

    # --- Aplicar valores por defecto ---
    # Si --active-since no fue especificado, usamos el valor calculado por defecto (timestamp numérico)
    if [[ -z "$CREATE_ACTIVE_SINCE_RAW" ]]; then
        CREATE_ACTIVE_SINCE_PARSED="$ACTIVE_SINCE_DEFAULT_TS"
    else
        # Si fue especificado, lo parseamos (puede ser timestamp numérico o cadena datetime)
        # Primero intentamos interpretarlo como número (timestamp)
        if [[ "$CREATE_ACTIVE_SINCE_RAW" =~ ^[0-9]+$ ]]; then
            CREATE_ACTIVE_SINCE_PARSED="$CREATE_ACTIVE_SINCE_RAW"
        else
            # Si no es número, asumimos que es una cadena datetime y la parseamos
            CREATE_ACTIVE_SINCE_PARSED=$(parse_datetime_to_timestamp "$CREATE_ACTIVE_SINCE_RAW") || exit 1
        fi
    fi

    # Si --active-till no fue especificado, usamos el valor calculado por defectoo)
    if [[ -z "$CREATE_ACTIVE_TILL_RAW" ]]; then
        CREATE_ACTIVE_TILL_PARSED="$ACTIVE_TILL_DEFAULT_TS"
    else
        # Si fue especificado, lo parseamos (puede ser timestamp numérico o cadena datetime)
        # Primero intentamos interpretarlo como número (timestamp)
        if [[ "$CREATE_ACTIVE_TILL_RAW" =~ ^[0-9]+$ ]]; then
            CREATE_ACTIVE_TILL_PARSED="$CREATE_ACTIVE_TILL_RAW"
        else
            # Si no es número, asumimos que es una cadena datetime y la parseamos
            CREATE_ACTIVE_TILL_PARSED=$(parse_datetime_to_timestamp "$CREATE_ACTIVE_TILL_RAW") || exit 1
        fi
    fi
    # --- Fin aplicación de valores por defecto ---

    # Validación de parámetros requeridos para create
    if [[ -z "$CREATE_NAME" || -z "$CREATE_PERIOD" ]]; then
        echo "Error: Parámetros requeridos faltantes para create: --name, --period." >&2
        show_help_create
        exit 1
    fi

    # Agregamos un prefijo al nombre del mantenimiento gestionado por este proyecto
    if [[ -n "$CREATE_NAME" ]]; then
        CREATE_NAME="${PREFIX_MAINTENANCE_NAME}${CREATE_NAME}"
    fi

    # Parseo de valores (timestamps, periodos)
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

    # Pasamos "create", el JSON, y el sector
    if ! execute_action_and_report "create" "$action_json" "$CREATE_SECTOR"; then
        # Si execute_action_and_report falla (retorno != 0), es porque hubo un error crítico en la ejecución del handler
        # y ya se reportó. Podemos salir del script aquí.
        echo "La creación del mantenimiento falló críticamente." >&2
        exit 1
    fi

    ## Funcionalidad de display post accion (maintenance.get)
    ## Display opcional o requerido después de create (si se especificó un sector)
    ## Por ahora, lo hacemos siempre si se especificó un sector.
    #if [[ -n "$CREATE_SECTOR" ]]; then # Asumiendo que defines CREATE_SECTOR en cmd_create o uses una variable global si aplica
    #    execute_display_and_report "$CREATE_NAME" "$CREATE_SECTOR"
    #    # Opcional: Manejar retorno
    #    # local disp_ret=$?
    #    # if [ $disp_ret -ne 0 ]; then
    #    #     echo "Advertencia: El proceso de display finalizó con errores." >&2
    #    # fi
    #fi

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
            --active-since)
                if [[ -z "$2" ]]; then echo "Error: --active-since requiere un valor." >&2; exit 1; fi
                UPDATE_ACTIVE_SINCE_RAW="$2"; shift 2 ;;
            --active-till)
                if [[ -z "$2" ]]; then echo "Error: --active-till requiere un valor." >&2; exit 1; fi
                UPDATE_ACTIVE_TILL_RAW="$2"; shift 2 ;;
            --type)
                if [[ -z "$2" ]]; then echo "Error: --type requiere un valor." >&2; exit 1; fi
                UPDATE_TYPE="$2"; shift 2 ;;
            --description)
                if [[ -z "$2" ]]; then echo "Error: --description requiere un valor." >&2; exit 1; fi
                UPDATE_DESCRIPTION="$2"; shift 2 ;;
            -H|--hostnames)
                if [[ -z "$2" ]]; then echo "Error: --hostnames requiere un valor." >&2; exit 1; fi
                UPDATE_HOSTNAMES="$2"; shift 2 ;;
            -G|--groupnames)
                if [[ -z "$2" ]]; then echo "Error: --groupnames requiere un valor." >&2; exit 1; fi
                UPDATE_GROUPNAMES="$2"; shift 2 ;;
            -S|--sector)
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
    local update_since_ts=""
    local update_till_ts=""

    if [[ -n "$UPDATE_PERIOD" ]]; then
        update_period_sec=$(parse_time_to_seconds "$UPDATE_PERIOD") || exit 1
    fi
    if [[ -n "$UPDATE_STARTDATE" ]]; then
        update_startdate_ts=$(parse_datetime_to_timestamp "$UPDATE_STARTDATE") || exit 1
    else
        update_startdate_ts="" # Dejar vacío si no se especificó
    fi

    # Parseo de active-since y active-till (igual que en create)
    if [[ -n "$UPDATE_ACTIVE_SINCE_RAW" ]]; then
        if [[ "$UPDATE_ACTIVE_SINCE_RAW" =~ ^[0-9]+$ ]]; then
            update_since_ts="$UPDATE_ACTIVE_SINCE_RAW"
        else
            update_since_ts=$(parse_datetime_to_timestamp "$UPDATE_ACTIVE_SINCE_RAW") || exit 1
        fi
    fi
    if [[ -n "$UPDATE_ACTIVE_TILL_RAW" ]]; then
        if [[ "$UPDATE_ACTIVE_TILL_RAW" =~ ^[0-9]+$ ]]; then
            update_till_ts="$UPDATE_ACTIVE_TILL_RAW"
        else
            update_till_ts=$(parse_datetime_to_timestamp "$UPDATE_ACTIVE_TILL_RAW") || exit 1
        fi
    fi

    # Asignamos a variables globales para el JSON
    UPDATE_PERIOD_SECONDS="$update_period_sec"
    UPDATE_STARTDATE_PARSED="$update_startdate_ts"
    UPDATE_ACTIVE_SINCE_PARSED="$update_since_ts"
    UPDATE_ACTIVE_TILL_PARSED="$update_till_ts"

    # Construimos el JSON de entrada para el handler, incluyendo la acción
    local action_json
    action_json=$(build_input_json_for_action "update")

    # Pasamos "update", el JSON, y el sector
    if ! execute_action_and_report "update" "$action_json" "$UPDATE_SECTOR"; then
        echo "La actualización del mantenimiento falló críticamente." >&2
        exit 1
    fi

    # Funcionalidad de display post accion (maintenance.get)
    ## Display opcional o requerido después de update
    #if [[ -n "$UPDATE_SECTOR" ]]; then
    #    execute_display_and_report "$UPDATE_NAME" "$UPDATE_SECTOR"
    #fi
}

cmd_delete() {
    # Parseo específico para delete
    while [[ $# -gt 0 ]]; do
        case $1 in
            -n|--name)
                if [[ -z "$2" ]]; then echo "Error: --name requiere un valor." >&2; exit 1; fi
                DELETE_NAME="$2"; shift 2 ;;
            -S|--sector)
                if [[ -z "$2" ]]; then echo "Error: --sector requiere un valor." >&2; exit 1; fi
                DELETE_SECTOR="$2"; shift 2 ;;
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

    # Construimos el JSON de entrada para el handler, incluyendo la acción
    local action_json
    action_json=$(build_input_json_for_action "delete")

    # Pasamos "delete", el JSON, y el sector
    if ! execute_action_and_report "delete" "$action_json" "$DELETE_SECTOR"; then
        echo "La eliminación del mantenimiento falló críticamente." >&2
        exit 1
    fi
}

cmd_list() {
    # No hay argumentos específicos para parsear en este subcomando
    # Solo recibe $@ vacío o con --help

    # Parseo específico para list (solo --help por ahora)
    while [[ $# -gt 0 ]]; do
        case $1 in
            --help|-h)
                show_help_list; exit 0 ;;
            *)
                echo "Error: opción desconocida para list: $1" >&2; show_help_list; exit 1 ;;
        esac
    done

    # Validar que PREFIX_MAINTENANCE_NAME esté definido
    if [[ -z "$PREFIX_MAINTENANCE_NAME" ]]; then
        echo "Error: El prefijo para listar mantenimientos (PREFIX_MAINTENANCE_NAME) no está definido." >&2
        exit 1
    fi

    echo "Listando mantenimientos con prefijo: '$PREFIX_MAINTENANCE_NAME'" >&2

    # Construimos el JSON de entrada para el handler, incluyendo la acción y el prefijo
    local action_json
    action_json=$(jq -n --arg url "$ZBX_URL" --arg token "$ZBX_APITOKEN" --arg act "list" --arg prefix "$PREFIX_MAINTENANCE_NAME" \
        '{
            zbx_url: $url,
            zbx_apitoken: $token,
            action: $act,
            maintenance_prefix: $prefix
        }')

    # Llamamos al handler JavaScript con el nuevo JSON
    local rsp_msg
    rsp_msg=$(zabbix_js -s "$MAINTENANCE_HANDLER_JS" -p "$action_json")
    local exit_code=$?

    if [ $exit_code -ne 0 ] || echo "$rsp_msg" | grep -q "error\|Problema"; then
        echo "Error: Falló la listado de mantenimientos." >&2
        echo "$rsp_msg" >&2
        exit 1
    else
        echo "Mantenimientos encontrados:"
        echo "$rsp_msg" | jq '.' # Usamos jq '.' para formatear bonito el JSON
        ###Formateo que ya no usamos->echo "$rsp_msg" | jq -r '.[] | "ID: \(.maintenanceid) - Name: \(.name)"' # Formatear salida si es un array
        # Opcional: enviar resultado a Zabbix (requiere item_id y sector si aplica)
        # local HOST_LOG="Registros de Mantenimientos"
        # local KEY_SECTOR="mantenimientos.list" # O usar el sector si aplica
        # local item_id=$(get_itemid "$ZBX_URL" "$ZBX_APITOKEN" "$HOST_LOG" "$KEY_SECTOR")
        # send_result "$ZBX_URL" "$ZBX_APITOKEN" "$item_id" "list_maintenance" "success" "$rsp_msg" "$HOST_LOG" "$KEY_SECTOR"
    fi
}

# =============================================================================
# 3. === INICIALIZACIÓN DEL SCRIPT ===
# =============================================================================

#set -e ##DEBUG
#set -u ##DEBUG

# Calcular valores por defecto para active_since y active_till
ACTIVE_SINCE_DEFAULT_TS=$(date +%s) # NOW en timestamp Unix
ACTIVE_TILL_DEFAULT_TS=$(( ACTIVE_SINCE_DEFAULT_TS + 3 * 365 * 24 * 3600 )) # NOW + 3 years

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
# Este loop debe PARAR cuando encuentre un subcomando, sin consumirlo aún de $@
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
        # Funcionalidad de prefix liberada, pero no probada. No recomendamos su uso aun
        --prefix)
            if [[ -z "$2" ]]; then echo "Error: --prefix requiere un valor." >&2; exit 1; fi
            RAW_PREFIX_MAINTENANCE_NAME="$2"; shift 2 ;;
        --help|-h)
            show_help_general; exit 0 ;;
        # Identificamos el subcomando, PERO NO LO CONSUMIMOS AÚN
        create|update|delete|list)
            COMMAND="$1"
            # Rompemos el loop global, $@ aún contiene el subcomando y sus args
            break
            ;;
        *)
            echo "Error: opción desconocida: $1" >&2; show_help_general; exit 1 ;;
    esac
done

# Si no se especificó subcomando (porque el loop consumió todos los args sin encontrar uno)
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
if [[ -n "$RAW_PREFIX_MAINTENANCE_NAME" ]]; then PREFIX_MAINTENANCE_NAME="$RAW_PREFIX_MAINTENANCE_NAME"; fi

# --- Inicio de lógica de autenticación ---
LOGGED_IN_INFO=""
SESSION_TOKEN=""
SESSION_USERNAME=""
if [[ -n "$ZBX_USER" && -n "$ZBX_PASSWORD" ]]; then
    echo "Iniciando sesión en Zabbix como '$ZBX_USER'..." >&2
    LOGGED_IN_INFO=$(zbx_login "$ZBX_URL" "$ZBX_USER" "$ZBX_PASSWORD")
    SESSION_TOKEN=$(jq -e -r '.sessionid' <<< "$LOGGED_IN_INFO" 2>/dev/null)
    SESSION_USERNAME=$(jq -e -r '.username' <<< "$LOGGED_IN_INFO" 2>/dev/null)
    ###Podriamos procesar en una sola linea: read -r SESSION_TOKEN USERNAME <<< "$(jq -r '[.sessionid, .username] | @tsv' <<< "$LOGGED_IN_INFO")"
    if [ $? -ne 0 ] || [ -z "$SESSION_TOKEN" ] || [ "$SESSION_TOKEN" == "null" ]; then
        echo "Error fatal: No se pudo iniciar sesión." >&2
        exit 1
    fi
    if [ $? -ne 0 ] || [ -z "$SESSION_USERNAME" ] || [ "$SESSION_USERNAME" == "null" ]; then
        echo "Error: No se pudo obtener el username de la sesión." >&2
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

# Ahora, SHIFT el subcomando de $@ para que queden solo los args específicos del subcomando
shift # Esto elimina el nombre del subcomando (e.g., 'create') de $@

# =============================================================================
# 5. === EJECUCIÓN DEL SUBCOMANDO ===
# =============================================================================

# Llamamos al subcomando con sus argumentos específicos
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
