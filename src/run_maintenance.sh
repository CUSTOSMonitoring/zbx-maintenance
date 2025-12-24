#!/bin/bash

# ==================================================================================
# run_maintenance.sh
# Script para ejecutar maintenance_handler.js vía zabbix_js
# Recibe parámetros por banderas y construye el JSON de entrada.
# Utiliza la API de Zabbix para registrar en Zabbix los mantenimientos por sector
# ==================================================================================

# Valores por defecto
ZBX_URL=""
ZBX_APITOKEN=""
MAINTENANCE_NAME=""
TIMEPERIOD_PERIOD=""
TIMEPERIOD_STARTDATE=""
GROUPNAMES=""
HOSTNAMES=""
SECTOR=""

# Archivo de configuración por defecto
CONFIG_FILE="default_params.conf"

# Cargamos configuración si existe
if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
else
    echo "Advertencia: Archivo de configuración '$CONFIG_FILE' no encontrado. Usando valores vacíos." >&2
fi

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

# Escapamos comillas dobles y barras invertidas para JSON
escape_json() {
    echo "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

# Construimos el JSON de entrada (al javascript) cada vez que se llama
build_input_json() {
    cat << EOF
{
  "zbx_url": "$ZBX_URL_ESC",
  "zbx_apitoken": "$ZBX_APITOKEN_ESC",
  "maintenance_name": "$MAINTENANCE_NAME_ESC",
  "timeperiod_period": "$TIMEPERIOD_PERIOD",
  "timeperiod_startdate": "$TIMEPERIOD_STARTDATE",
  "groupnames": "$GROUPNAMES_ESC",
  "hostnames": "$HOSTNAMES_ESC",
  "sector": "$SECTOR",
  "run_mode": "$RUN_MODE"
}
EOF
}

# Función para enviar mensajes (y errores) por history.push via API y stdout
send_result() {
    local url_fe="$1"      # La URL del Zabbix Frontend
    local token="$2"       # API Token de Zabbix
    local item_id="$3"     # ID del item en el cual vamos a loguear los resultados de la operacion
    local mode="$4"        # update_maintenance, display_maintenance
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
    # para evitar romper con la estructura JSON del request al ingresar un $value que sea JSONs
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
    
    #Imprimimos el result, pero si no existe no imprimimos nada, no da error
    echo "$response" | jq -r '.result // empty'
    return 0
}


# Función: mostrar ayuda
show_help() {
    cat << 'EOF'
Uso: run_maintenance.sh [OPCIONES]

Script para gestionar los mantenimientos de los hosts en Zabbix.
A través de este script se puede agregar host o quitar hosts de mantenimiento por sector, asi como también modificar los parametros del mantenimiento como fechas de mantenimiento o longitud del mismo.

Opciones:
    -u, --zbx-url URL               URL del API de Zabbix (ej: https://zabbix/api_jsonrpc.php)
    -t, --zbx-apitoken TOKEN        Token de API de Zabbix
    -m, --maintenance-name NAME     Nombre del mantenimiento a actualizar
    -p, --timeperiod-period SEC     Duración del periodo de mantenimiento en segundos
    -s, --timeperiod-startdate DATE Fecha de inicio (timestamp). Si se omite, se usa NOW.
    -g, --groupnames LIST           Lista de grupos separados por comas (ej: "Linux servers,VMs")
    -H, --hostnames LIST            Lista de hosts separados por comas (ej: "srv01,srv02")
    -S, --sector NAME               Sector responsable del mantenimiento. Requerido para dejar registro de los mantenimientos
    -h, --help                      Muestra esta ayuda y sale

Ejemplo:
    ./run_maintenance.sh \
        --zbx-url https://172.221.101.221/api_jsonrpc.php \
        --zbx-apitoken 9206104e1ab5b7c49aae94b008e17b310d99317f2d05f714baf8ac45bb672315 \
        --maintenance-name "Infra Maintenance" \
        --timeperiod-period 7200 \
        --hostnames "Serv1, test-srv, Switch123" \
        --groupnames "Critical servers" \
        --sector "Infra"

Notas:
    - Si --timeperiod-startdate no se especifica, se usará el timestamp actual.
    - Los valores que contengan espacios deben ir entre comillas.
EOF
}

# Parseo de argumentos
while [[ $# -gt 0 ]]; do
    case $1 in
        -u|--zbx-url)
            ZBX_URL="$2"
            shift 2
            ;;
        -t|--zbx-apitoken)
            ZBX_APITOKEN="$2"
            shift 2
            ;;
        -m|--maintenance-name)
            MAINTENANCE_NAME="$2"
            shift 2
            ;;
        -p|--timeperiod-period)
	    # Convertimos el valor a segundos
	    if [[ -z "$2" ]]; then
                echo "Error: --timeperiod-period requiere un valor." >&2
                exit 1
            fi
            TIMEPERIOD_PERIOD="$2"
	    ####Validacion (y transformacion) la hacemos mas adelante
            ###raw_period="$2"
            ###TIMEPERIOD_PERIOD=$(parse_time_to_seconds "$raw_period")
            ###if [[ $? -ne 0 ]]; then
            ###    echo "Fallo al procesar el periodo: $raw_period" >&2
            ###    exit 1
            ###fi
            shift 2
            ;;
        -s|--timeperiod-startdate)
	    if [[ -z "$2" ]]; then
                echo "Error: --timeperiod-startdate requiere un valor." >&2
                exit 1
            fi
            raw_date="$2"
            TIMEPERIOD_STARTDATE=$(parse_datetime_to_timestamp "$raw_date")
            if [[ $? -ne 0 ]]; then
                echo "Fallo al procesar la fecha: $raw_date" >&2
                exit 1
            fi
            shift 2
            ;;
        -g|--groupnames)
            GROUPNAMES="$2"
            shift 2
            ;;
        -H|--hostnames)
            HOSTNAMES="$2"
            shift 2
            ;;
        -S|--sector)
            SECTOR="$2"
            shift 2
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            echo "Error: opción desconocida: $1" >&2
            echo "Use --help para ver las opciones disponibles." >&2
            exit 1
            ;;
    esac
done

# Validación de campos obligatorios
if [[ -z "$ZBX_URL" || -z "$ZBX_APITOKEN" || -z "$MAINTENANCE_NAME" || -z "$TIMEPERIOD_PERIOD" ]]; then
    echo "Error: Faltan parámetros obligatorios." >&2
    echo "Los siguientes parámetros son obligatorios: --zbx-url, --zbx-apitoken, --maintenance-name, --timeperiod-period" >&2
    echo "Use --help para ver el uso." >&2
    exit 1
fi

# Si no se especifica startdate, usar timestamp actual
if [[ -z "$TIMEPERIOD_STARTDATE" ]]; then
    TIMEPERIOD_STARTDATE=$(date +%s)
fi


#Validamos timeperiod
TIMEPERIOD_PERIOD=$(parse_time_to_seconds "$TIMEPERIOD_PERIOD")
if [[ $? -ne 0 ]]; then
    echo "Fallo al procesar el periodo: $raw_period" >&2
    exit 1
fi

ZBX_URL_ESC=$(escape_json "$ZBX_URL")
ZBX_APITOKEN_ESC=$(escape_json "$ZBX_APITOKEN")
MAINTENANCE_NAME_ESC=$(escape_json "$MAINTENANCE_NAME")
GROUPNAMES_ESC=$(escape_json "$GROUPNAMES")
HOSTNAMES_ESC=$(escape_json "$HOSTNAMES")
RUN_MODE="update_maintenance"

HOST_LOG="Registros de Mantenimientos"
KEY_SECTOR="mantenimientos.${SECTOR}"

item_id=$(get_itemid "$ZBX_URL_ESC" "$ZBX_APITOKEN_ESC" "$HOST_LOG" "$KEY_SECTOR")

# Construimos el json de entrada del maintenance_handler.js
INPUT_JSON="$(build_input_json)"

echo "🚀 Ejecutando: update_maintenance..."

# Ejecutamos zabbix_js con el JSON como parámetro
rsp_msg=$(zabbix_js -s maintenance_handler.js -p "$INPUT_JSON")
exit_code=$?
if [ $exit_code -ne 0 ] || echo "$rsp_msg" | grep -q "error\|Problema"; then
    send_result "$ZBX_URL_ESC" "$ZBX_APITOKEN_ESC" "$item_id" "update_maintenance" "error" "zabbix_js falló o devolvió error: $rsp_msg" "$HOST_LOG" "$KEY_SECTOR"
    exit 1
else
    send_result "$ZBX_URL_ESC" "$ZBX_APITOKEN_ESC" "$item_id" "update_maintenance" "success" "$rsp_msg" "$HOST_LOG" "$KEY_SECTOR"
fi

# Cambiamos el modo de ejecucion a "mostrar resultados"
RUN_MODE="display_maintenance"
INPUT_JSON="$(build_input_json)"

rsp_msg=$(zabbix_js -s maintenance_handler.js -p "$INPUT_JSON")
exit_code=$?

if [ $exit_code -ne 0 ] || echo "$rsp_msg" | grep -q "error\|Problema\|null"; then
    send_result "$ZBX_URL_ESC" "$ZBX_APITOKEN_ESC" "$item_id" "display_maintenance" "error" "No se pudo obtener estado actual: $rsp_msg" "$HOST_LOG" "$KEY_SECTOR"
    # No es crítico, pero debe reportarse
else
    send_result "$ZBX_URL_ESC" "$ZBX_APITOKEN_ESC" "$item_id" "display_maintenance" "success" "$rsp_msg" "$HOST_LOG" "$KEY_SECTOR"
fi

# Capturar el código de salida
EXIT_CODE=$?

# Manejo básico del error
if [ $EXIT_CODE -ne 0 ]; then
    echo "Error: zabbix_js falló con código $EXIT_CODE" >&2
    exit $EXIT_CODE
fi

exit 0
