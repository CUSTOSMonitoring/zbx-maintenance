/*
 * maintenance_handler.js
 * Script para interactuar con la API de Zabbix y gestionar mantenimientos.
*/



// Extrae los valores de una propiedad específica de un array de objetos y retorna un array con los valores extraídos
function extractIds(jsonData, prop_id) {
    // Validación: si jsonData es null, undefined, o no es un array, retornar null
    if (!Array.isArray(jsonData)) {
        return null;
    }

    // Validación: si prop_id no es un string válido
    if (typeof prop_id !== 'string' || prop_id === '') {
        return null;
    }

    // Extraemos solo los elementos que tienen la propiedad `prop_id`
    return jsonData
        .filter(function(item) {
            return item.hasOwnProperty(prop_id);
        }) // Solo objetos con la propiedad
        .map(function(item) {
            return item[prop_id];
        }); // Extraemos el valor de esa propiedad
}

// Transforma nombres separados por , en un array de nombres
function parse_names(names_in) {
    // Si no se recibe nada o no es un string, devolvemos un array vacío
    if (typeof names_in !== 'string') {
        return [];
    }

    // Split por comas, eliminamos espacios extra y filtramos entradas vacías
    return names_in.split(',')
               .map(function(str_in) {
                   return str_in.trim();
               })
               .filter(function(str_in) {
                   return str_in.length > 0;
               });
}


// Obtiene los hostids de los hosts ingresados en hostnames
function get_host_id(url, token, hostnames) {
    // Validación inicial: si hostnames es null, undefined o un array vacío, retornamos null
    if (hostnames == null || (Array.isArray(hostnames) && hostnames.length === 0)) {
        return null;
    }

    try {
        req = new HttpRequest();
        req.addHeader('Content-Type: application/json');
        req.addHeader('Authorization: Bearer ' + token);

        jdata = {
            "jsonrpc": "2.0",
            "method": "host.get",
            "params": {
                "filter": {
                    "name": hostnames
                },
                "output": ["hostid"]
            },
            "id": 1
        };

        var response = req.get(url, JSON.stringify(jdata));
        var hostids_arr = JSON.parse(response).result;
        return hostids_arr;

    } catch (error) {
        return { "error": "Problema al encontrar el/los host/s: " + error };
    }
}


// Obtiene los groupids de los grupos ingresados en groupnames
function get_group_id(url, token, groupnames) {
    // Validación inicial: si groupnames es null, undefined, o un array vacío, retornamos null
    if (groupnames == null || (Array.isArray(groupnames) && groupnames.length === 0)) {
        return null;
    }

    try {
        req = new HttpRequest();
        req.addHeader('Content-Type: application/json');
        req.addHeader('Authorization: Bearer ' + token);

        jdata = {
            "jsonrpc": "2.0",
            "method": "hostgroup.get",
            "params": {
                "filter": {
                    "name": groupnames
                },
                "output": ["groupid"]
            },
            "id": 1
        };

        var response = req.get(url, JSON.stringify(jdata));
        var groupids_arr = JSON.parse(response).result;
        return groupids_arr;

    } catch (error) {
        return { "error": "Problema al encontrar el/los hostgroup/s: " + error };
    }
}

// Obtiene el id del maintenance ingresado en maintenance_name
// Cond: Solo se permite un maintenance_name
function get_maintenance_id(url, token, maintenance_name) {
    // Validación inicial: si maintenance_name es null, undefined o cadena vacía, retornamos null
    if (maintenance_name == null || maintenance_name === "") {
        return null;
    }

    try {
        req = new HttpRequest();
        req.addHeader('Content-Type: application/json');
        req.addHeader('Authorization: Bearer ' + token);

        jdata = {
            "jsonrpc": "2.0",
            "method": "maintenance.get",
            "params": {
                "filter": {
                    "name": maintenance_name
                },
                "output": ["maintenanceid"]
            },
            "id": 1
        };

        var response = req.get(url, JSON.stringify(jdata));
        var maintenanceids_arr = JSON.parse(response).result;
        return maintenanceids_arr;

    } catch (error) {
        return { "error": "Problema al encontrar el/los mantenimiento/s: " + error };
    }
}

function display_maintenance(url, token, maintenance_id) {
    // Validación inicial: si maintenance_name es null, undefined o cadena vacía, retornamos null
    if (maintenance_id == null || maintenance_id === "") {
        return null;
    }

    try {
        req = new HttpRequest();
        req.addHeader('Content-Type: application/json');
        req.addHeader('Authorization: Bearer ' + token);

        jdata = {
            "jsonrpc": "2.0",
            "method": "maintenance.get",
            "params": {
                "maintenanceids": maintenance_id,
                "output": [
                    "maintenanceid",
                    "name",
                    "maintenance_type",
                    "description"
		],
                "selectTimeperiods": ["period", "start_date"],
                "selectHosts": ["name"],
                "selectHostGroups": ["name"]
            },
            "id": 1
        };

        var response = req.get(url, JSON.stringify(jdata));
        var maintenance_info = JSON.parse(response).result;
        return maintenance_info;

    } catch (error) {
        return { "error": "Problema al encontrar el/los mantenimiento/s: " + error };
    }
}


//MaintenanceInfo[0].hosts = extractIds(MaintenanceInfo[0].hosts, "name");
function format_display(maintenance_info) {
    maintenance_info[0].hostgroups = extractIds(maintenance_info[0].hostgroups, "name");
    maintenance_info[0].hosts = extractIds(maintenance_info[0].hosts, "name");
    return maintenance_info;
}

// Actualizamos un mantenimiento existente en Zabbix
// Ahora puede actualizar timeperiods, hosts, groups, active_since, active_till, maintenance_type y description
function upd_maintenance(url, token, maintenance_id, timeperiod_startdate, timeperiod_period, hostids, groupids, active_since, active_till, maint_type, new_description) {
    // Validación: maintenance_id debe ser un valor válido (no null, undefined, vacío)
    if (maintenance_id == null || maintenance_id === "") {
        return { "error": "ID de mantenimiento inválida para actualizar." };
    }

    // Validación: timeperiod_period debe ser un número positivo si se provee
    if (typeof timeperiod_period !== 'undefined' && timeperiod_period !== null && (typeof timeperiod_period !== 'number' || timeperiod_period <= 0)) {
        return { "error": "timeperiod_period debe ser un número positivo." };
    }

    // Validación: active_since y active_till deben ser números si se proveen
    if (typeof active_since !== 'undefined' && active_since !== null && (typeof active_since !== 'number')) {
        return { "error": "active_since debe ser un timestamp UNIX válido." };
    }
    if (typeof active_till !== 'undefined' && active_till !== null && (typeof active_till !== 'number')) {
        return { "error": "active_till debe ser un timestamp UNIX válido." };
    }

    // Validación: maint_type debe ser 0 o 1 si se provee
    if (typeof maint_type !== 'undefined' && maint_type !== null && (maint_type !== 0 && maint_type !== 1)) {
        return { "error": "maintenance_type debe ser 0 (With data collection) o 1 (No data)." };
    }

    // Validación: hostids y groupids deben ser un array o null
    // Si se proveen, verificamos que sean arrays
    if (hostids !== null && !Array.isArray(hostids)) {
        return { "error": "hostids debe ser un array de objetos {hostid: '...'} o null." };
    }
    if (groupids !== null && !Array.isArray(groupids)) {
        return { "error": "groupids debe ser un array de objetos {groupid: '...'} o null." };
    }

    try {
        var req = new HttpRequest();
        req.addHeader('Content-Type: application/json');
        req.addHeader('Authorization: Bearer ' + token);

        // Construimos el cuerpo de la solicitud
        var jdata = {
            "jsonrpc": "2.0",
            "method": "maintenance.update",
            "params": {
                "maintenanceid": maintenance_id
            },
            "id": 1
        };

        // Solo actualizamos timeperiods si se especificaron nuevos valores
        if ((timeperiod_startdate !== null && typeof timeperiod_startdate !== 'undefined') || (timeperiod_period !== null && typeof timeperiod_period !== 'undefined')) {
            // Se asume que se quiere actualizar el primer (y único) timeperiod existente
            // Usamos timeperiod_startdate si está especificado, sino usamos NOW
            var start_date;
            if (timeperiod_startdate != null && !isNaN(timeperiod_startdate)) {
                start_date = Math.floor(timeperiod_startdate);
            } else {
                start_date = Math.floor(Date.now() / 1000);
            }
            // Usamos timeperiod_period si está especificado
            var period = timeperiod_period !== null && typeof timeperiod_period !== 'undefined' ? timeperiod_period : 3600; // Valor por defecto si no se provee, aunque debería venir siempre si se especifica startdate

            jdata.params.timeperiods = [{
                "start_date": start_date,
                "period": period
            }];
        }

        // Solo agregamos hosts si se proporcionaron explícitamente (puede ser [])
        if (hostids !== null) {
            jdata.params.hosts = hostids;
        }

        // Solo agregamos groups si se proporcionaron explícitamente (puede ser [])
        if (groupids !== null) {
            jdata.params.groups = groupids;
        }

        // --- NUEVA LOGICA PARA active_since, active_till, maintenance_type ---
        // Solo actualizamos estos campos si se especificaron nuevos valores
        if (active_since !== null && typeof active_since !== 'undefined') {
            jdata.params.active_since = active_since;
        }

        if (active_till !== null && typeof active_till !== 'undefined') {
            jdata.params.active_till = active_till;
        }

        if (maint_type !== null && typeof maint_type !== 'undefined') {
            jdata.params.maintenance_type = maint_type;
        }

        // Solo actualizamos la descripción si se especificó un nuevo valor
        if (new_description !== null && typeof new_description !== 'undefined') {
            jdata.params.description = new_description;
        }
        // --- FIN NUEVA LOGICA ---

        // Enviamos la solicitud
        var response = req.get(url, JSON.stringify(jdata));

        // Intentamos parsear la respuesta
        var parsedResponse = JSON.parse(response);

        // Verificar si la API devolvió un error
        if (parsedResponse.error) {
            var errorMessage = parsedResponse.error.data || parsedResponse.error.message || "Error desconocido de la API de Zabbix.";
            return { "error": "Error de la API de Zabbix en update_maintenance: " + errorMessage };
        }

        return parsedResponse.result;

    } catch (error) {
        return { "error": "Problema al actualizar el mantenimiento: " + error };
    }
}


/**
 * Crea un nuevo mantenimiento en Zabbix.
 *
 * @param {string} url - URL del endpoint de la API de Zabbix.
 * @param {string} token - Token de API o Session Token.
 * @param {string} maintenance_name - Nombre del mantenimiento.
 * @param {number} maintenance_active_since - Timestamp Unix de inicio del mantenimiento.
 * @param {number} maintenance_active_till - Timestamp Unix de fin del mantenimiento.
 * @param {number} maintenance_type - Tipo de mantenimiento (0: Normal, 1: No Data). Por defecto 0.
 * @param {number} timeperiod_startdate - Timestamp Unix del inicio del período de mantenimiento.
 * @param {number} timeperiod_period - Duración del período en segundos.
 * @param {Array|null} hostids - Array de objetos hostid: [{"hostid": "1"}, ...] o null.
 * @param {Array|null} groupids - Array de objetos groupid: [{"groupid": "2"}, ...] o null.
 * @param {string} maintenance_description - Descripción del mantenimiento (opcional).
 * @returns {Object|string} - Resultado de la API o mensaje de error.
 */
function create_maintenance(url, token, maintenance_name, maintenance_active_since, maintenance_active_till, maintenance_type, timeperiod_startdate, timeperiod_period, hostids, groupids, maintenance_description) {

    // Validación básica de parámetros requeridos
    if (!url || !token || !maintenance_name || typeof maintenance_active_since !== 'number' || typeof maintenance_active_till !== 'number' || typeof timeperiod_startdate !== 'number' || typeof timeperiod_period !== 'number') {
        return "Error: Parámetros inválidos para create_maintenance.";
    }

    // Asegurar valores por defecto
    if (typeof maintenance_type === 'undefined' || maintenance_type === null) {
        maintenance_type = 0; // With data collection
    }

    // Asegurar una descripción vacía si no se proporciona
    if (typeof maintenance_description === 'undefined' || maintenance_description === null) {
        maintenance_description = ""; // Cadena vacía por defecto
    }

    try {
        var req = new HttpRequest();
        req.addHeader('Content-Type: application/json');
        req.addHeader('Authorization: Bearer ' + token);

        var jdata = {
            "jsonrpc": "2.0",
            "method": "maintenance.create",
            "params": {
                "name": maintenance_name,
                "active_since": maintenance_active_since,
                "active_till": maintenance_active_till,
                "maintenance_type": maintenance_type,
                "timeperiods": [
                    {
                        "timeperiod_type": 0, // One time only
                        "start_date": timeperiod_startdate,
                        "period": timeperiod_period
                    }
                ]
            },
            "id": 1
        };


        // Agregar hosts si se proveen
        if (hostids && Array.isArray(hostids) && hostids.length > 0) {
            jdata.params.hosts = hostids;
        }

        // Agregar grupos si se proveen
        if (groupids && Array.isArray(groupids) && groupids.length > 0) {
            jdata.params.groups = groupids;
        }

        if (maintenance_description !== null && typeof maintenance_description !== 'undefined') {
            jdata.params.description = maintenance_description;
        }

        var response = req.get(url, JSON.stringify(jdata));

        // Intentar parsear la respuesta
        var parsedResponse = JSON.parse(response);

        // Verificar si la API devolvió un error
        if (parsedResponse.error) {
            var errorMessage = parsedResponse.error.data || parsedResponse.error.message || "Error desconocido de la API de Zabbix.";
            return { "error": "Error de la API de Zabbix en create_maintenance: " + errorMessage };
        }

        // Devolver el resultado exitoso
        return parsedResponse.result;

    } catch (error) {
        return { "error": "Error al crear el mantenimiento: " + error };

    }
}

/**
 * Obtiene una lista de mantenimientos cuyo nombre comienza con un prefijo específico.
 *
 * @param {string} url - URL del endpoint de la API de Zabbix.
 * @param {string} token - Token de API o Session Token.
 * @param {string} maintenance_prefix - Prefijo del nombre de los mantenimientos a buscar.
 * @returns {Array|Object} - Array de objetos {maintenanceid, name} o un objeto {error: "mensaje"}.
 */
function list_maintenances(url, token, maintenance_prefix) {
    // Validación básica de parámetros
    if (!url || !token || typeof maintenance_prefix !== 'string') {
        return { "error": "Parámetros inválidos para list_maintenances." };
    }

    try {
        var req = new HttpRequest();
        req.addHeader('Content-Type: application/json');
        req.addHeader('Authorization: Bearer ' + token);

        var jdata = {
            "jsonrpc": "2.0",
            "method": "maintenance.get",
            "params": {
                // Usamos 'search' para buscar por nombre
                "search": {
                    "name": maintenance_prefix
                },
                // Usamos 'startSearch' para que coincida solo al inicio del nombre
                "startSearch": true,
                //Version anterior ->// Solicitamos solo las propiedades requeridas
                //"output": ["maintenanceid", "name"]
                // Solicitamos todas las propiedades extendidas y relaciones
                "output": "extend", // Esto incluye maintenanceid, name, maintenance_type, description, active_since, active_till
                "selectTimeperiods": "extend", // Incluye los períodos de tiempo
                "selectHosts": ["hostid", "name"], // Incluye hosts asociados (solo id y nombre)
                "selectHostGroups": ["groupid", "name"] // Incluye grupos de hosts asociados (solo id y nombre)
            },
            "id": 1
        };

        var response = req.get(url, JSON.stringify(jdata));

        // Intentar parsear la respuesta
        var parsedResponse = JSON.parse(response);

        // Verificar si la API devolvió un error
        if (parsedResponse.error) {
            var errorMessage = parsedResponse.error.data || parsedResponse.error.message || "Error desconocido de la API de Zabbix.";
            return { "error": "Error de la API de Zabbix en list_maintenance: " + errorMessage };
        }


        // Devolver la lista de mantenimientos encontrados
        // Si no hay coincidencias, la API devuelve un array vacío []
        return parsedResponse.result;

    } catch (error) {
        return { "error": "Error al listar los mantenimientos: " + error };
    }
}

/**
 * Elimina uno o más mantenimientos en Zabbix.
 *
 * @param {string} url - URL del endpoint de la API de Zabbix.
 * @param {string} token - Token de API o Session Token.
 * @param {string|array} maintenance_ids - ID único o array de IDs de los mantenimientos a eliminar.
 * @returns {Object} - Resultado de la API o objeto de error.
 */
function delete_maintenance(url, token, maintenance_ids) {
    // Validación básica de parámetros requeridos
    if (!url || !token || !maintenance_ids) {
        return { "error": "Parámetros inválidos para delete_maintenance." };
    }

    // Asegurar que maintenance_ids sea un array
    var ids_to_delete = Array.isArray(maintenance_ids) ? maintenance_ids : [maintenance_ids];

    try {
        var req = new HttpRequest();
        req.addHeader('Content-Type: application/json');
        req.addHeader('Authorization: Bearer ' + token);

        var jdata = {
            "jsonrpc": "2.0",
            "method": "maintenance.delete",
            "params": ids_to_delete, // params es un array directo, no un objeto
            "id": 1
        };

        var response = req.get(url, JSON.stringify(jdata));

        // Intentar parsear la respuesta
        var parsedResponse = JSON.parse(response);

        // Verificar si la API devolvió un error
        if (parsedResponse.error) {
            var errorMessage = parsedResponse.error.data || parsedResponse.error.message || "Error desconocido de la API de Zabbix.";
            return { "error": "Error de la API Zabbix en delete_maintenance: " + errorMessage };
        }

        // Devolver el resultado exitoso (array de IDs eliminados)
        return parsedResponse.result;

    } catch (error) {
        // En caso de error de JS/Red, también devolvemos un objeto
        return { "error": "Error al eliminar el/los mantenimiento/s: " + error };
    }
}


// --- LÓGICA PRINCIPAL: Leer 'action' y llamar a la función correspondiente ---

try {
    var input = JSON.parse(value);

    var action = input.action;
    var url = input.zbx_url;
    var token = input.zbx_apitoken;
    var maintenanceName = input.maintenance_name;

    var result;

    switch(action) {
        case 'create':
            // Parsear nombres de hosts y grupos
            var hostnames_arr = parse_names(input.hostnames || "");
            var groupnames_arr = parse_names(input.groupnames || "");

            // Obtener IDs de hosts y grupos
            var hostObjects = get_host_id(url, token, hostnames_arr);
            var groupObjects = get_group_id(url, token, groupnames_arr);

            // Extraer solo los IDs numéricos como objetos {hostid: "..."} o {groupid: "..."}
            var hostIds = (hostObjects && Array.isArray(hostObjects)) ? extractIds(hostObjects, "hostid").map(function(id) { return {"hostid": id}; }) : [];
            var groupIds = (groupObjects && Array.isArray(groupObjects)) ? extractIds(groupObjects, "groupid").map(function(id) { return {"groupid": id}; }) : [];

            // Validar que no haya errores en la obtención de IDs antes de llamar a create
            if (hostObjects && hostObjects.error) {
                 result = hostObjects; // Devuelve el objeto de error
            } else if (groupObjects && groupObjects.error) {
                 result = groupObjects; // Devuelve el objeto de error
            } else {
                 // Llamar a create_maintenance con los IDs extraídos
                 result = create_maintenance(
                     url,
                     token,
                     maintenanceName,
                     input.maintenance_active_since,
                     input.maintenance_active_till,
                     input.maintenance_type,
                     input.timeperiod_startdate,
                     input.timeperiod_period,
                     hostIds, // Pasar array de {hostid: "..."}
                     groupIds, // Pasar array de {groupid: "..."}
                     input.maintenance_description
                 );
            }
            break;
        case 'update':
            // Parsear nombres de hosts y grupos
            var hostnames_arr = parse_names(input.hostnames || "");
            var groupnames_arr = parse_names(input.groupnames || "");

            // Obtener IDs de hosts y grupos
            var hostObjects = get_host_id(url, token, hostnames_arr);
            var groupObjects = get_group_id(url, token, groupnames_arr);

            // Extraer solo los IDs numéricos como objetos {hostid: "..."} o {groupid: "..."}
            // IMPORTANTE: Si get_host_id/get_group_id devuelve un error, extractIds devolverá null.
            // Por lo tanto, hostIds y groupIds serán arrays de objetos o null.
            var hostIds = (hostObjects && Array.isArray(hostObjects)) ? extractIds(hostObjects, "hostid").map(function(id) { return {"hostid": id}; }) : null; // Pasa null si no hay hosts
            var groupIds = (groupObjects && Array.isArray(groupObjects)) ? extractIds(groupObjects, "groupid").map(function(id) { return {"groupid": id}; }) : null; // Pasa null si no hay groups

            // Obtener ID del mantenimiento a actualizar
            var maintenanceDetails = get_maintenance_id(url, token, maintenanceName);
            var maintenanceId = null;
            if (Array.isArray(maintenanceDetails) && maintenanceDetails.length > 0) {
                maintenanceId = extractIds(maintenanceDetails, "maintenanceid")[0];
            }

            if (!maintenanceId) {
                 result = {"error": "Mantenimiento no encontrado para actualizar: " + maintenanceName};
            } else if (hostObjects && hostObjects.error) {
                 result = hostObjects; // Devuelve el objeto de error
            } else if (groupObjects && groupObjects.error) {
                 result = groupObjects; // Devuelve el objeto de error
            } else {
                 // Extraer los nuevos parámetros opcionales
                 var activeSince = input.maintenance_active_since; // Debe ser un número (timestamp) o undefined/null
                 var activeTill = input.maintenance_active_till;   // Debe ser un número (timestamp) o undefined/null
                 var maintType = input.maintenance_type;         // Debe ser 0 o 1 o undefined/null
                 var newDescription = input.maintenance_description; // Puede ser una cadena o undefined/null


                 // Llamar a upd_maintenance con los IDs extraídos y los nuevos parámetros
                 result = upd_maintenance(
                     url,
                     token,
                     maintenanceId,
                     input.timeperiod_startdate, // Puede ser null/undefined
                     input.timeperiod_period,    // Puede ser null/undefined
                     hostIds,                    // Puede ser null
                     groupIds,                   // Puede ser null
                     activeSince,                // Puede ser null/undefined
                     activeTill,                 // Puede ser null/undefined
                     maintType,                  // Puede ser null/undefined
                     newDescription              // Puede ser null/undefined
                 );
            }
            break;
        case 'display':
            // Lógica para display (ejemplo, usando la función existente)
            var maintenanceDetails = get_maintenance_id(url, token, maintenanceName);
            var maintenanceId = null;
            if (Array.isArray(maintenanceDetails) && maintenanceDetails.length > 0) {
                maintenanceId = extractIds(maintenanceDetails, "maintenanceid")[0];
            }
            if (maintenanceId) {
                 var displayInfo = display_maintenance(url, token, maintenanceId);
                 if (displayInfo && Array.isArray(displayInfo) && displayInfo.length > 0) {
                     result = format_display(displayInfo)[0]; // Formatear y devolver el primer elemento
                     if (input.username && typeof input.username === 'string' && input.username.length > 0) {
                         result.performed_by = input.username;
                         result.performed_at = Math.floor(Date.now() / 1000); // Timestamp Unix de cuándo se consultó
                     }
                 } else {
                     result = {"error": "No se pudo obtener la información detallada del mantenimiento."};
                 }
            } else {
                 result = {"error": "Mantenimiento no encontrado para mostrar: " + maintenanceName};
            }
            break;
        case 'delete':
            // Obtener ID del mantenimiento a eliminar a partir del nombre
            var maintenanceDetails = get_maintenance_id(url, token, maintenanceName);
            var maintenanceId = null;
            
            // Extraer el maintenanceid si se encontró el mantenimiento
            if (Array.isArray(maintenanceDetails) && maintenanceDetails.length > 0) {
                maintenanceId = extractIds(maintenanceDetails, "maintenanceid")[0];
            }

            // Validar que se encontró el mantenimiento
            if (!maintenanceId) {
                result = { "error": "Mantenimiento no encontrado para eliminar: " + maintenanceName };
            } else {
                // Llamar a delete_maintenance con el ID obtenido
                // delete_maintenance espera un string o array de IDs
                result = delete_maintenance(url, token, maintenanceId);
            }
            break;
        case 'list':
            result = list_maintenances(url, token, input.maintenance_prefix);
            break;
        default:
            result = {"error": "Acción desconocida recibida: " + action};
    }

    // Devolver el resultado como string JSON
    return JSON.stringify(result);

} catch (e) {
    return JSON.stringify({"error": "Error procesando la solicitud en el handler: " + e.message});
}

// Fin del script
