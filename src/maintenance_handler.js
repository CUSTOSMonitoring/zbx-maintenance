/*
 * maintenance_handler.js
 * Script para interactuar con la API de Zabbix y gestionar mantenimientos.
 * Ahora soporta múltiples acciones: create, update, display.
 */

// --- Funciones existentes (mantenerlas tal cual o con pequeñas correcciones) ---

function extractIds(jsonData, prop_id) {
    if (jsonData == "null") {
        return "null";
    } else {
        var ids_arr = [];
        for (var i = 0; i < jsonData.length; i++) {
            if (jsonData[i][prop_id]) {
                ids_arr.push(jsonData[i][prop_id]);
            }
        }
    }
        return ids_arr;
}

function parse_names(names_in) {
    // Transformamos nombres separados por , en una lista de nombres
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

function get_host_id(url, token, hostnames){
    //Obtenemos los hostids de los hosts ingresados en hostnames
    if (hostnames== "null" || hostnames.length === 0) {
        return [];
    } else {
        try {
            var req = new HttpRequest();
            req.addHeader('Content-Type: application/json');
            req.addHeader('Authorization: Bearer ' + token);
            var jdata = { "jsonrpc": "2.0",
                      "method": "host.get",
                      "params": {
                          "filter": {
                              "name": hostnames
                          },
                          "output": ["hostid", "name"] // Pedimos también el nombre para info
                      },
                      "id": 1
                    };
            var hostids_arr = JSON.parse( req.get( url, JSON.stringify( jdata ) ) ).result;
            return hostids_arr;
        }
        catch (error) {
            return { "error": "Problema al encontrar el/los host/s: " + error };
        }
    }
}

function get_group_id(url, token, groupnames){
    //Obtenemos los groupids de los grupos ingresados en groupnames
    if (groupnames == "null" || groupnames.length === 0) {
        return [];
    } else {
        try {
            var req = new HttpRequest();
            req.addHeader('Content-Type: application/json');
            req.addHeader('Authorization: Bearer ' + token);
            var jdata = { "jsonrpc": "2.0",
                      "method": "hostgroup.get",
                      "params": {
                          "filter": {
                              "name": groupnames
                          },
                          "output": ["groupid", "name"] // Pedimos también el nombre para info
                      },
                      "id": 1
                    };
            var groupids_arr = JSON.parse( req.get( url, JSON.stringify( jdata ) ) ).result;
            return groupids_arr;
        }
        catch (error) {
            return { "error": "Problema al encontrar el/los hostgroup/s: " + error };
        }
    }
}

function get_maintenance_id(url, token, maintenance_name){
    //Obtenemos el id del maintenance de nombre maintenance_name
    if (maintenance_name == "null" || maintenance_name.length === 0) {
        return [];
    } else {
        try {
            var req = new HttpRequest();
            req.addHeader('Content-Type: application/json');
            req.addHeader('Authorization: Bearer ' + token);
            var jdata = { "jsonrpc": "2.0",
                      "method": "maintenance.get",
                      "params": { "filter": {
                                      "name": maintenance_name
                                  },
                                  "output": ["maintenanceid", "name", "active_since", "active_till", "timeperiods", "hosts", "hostgroups"] // Info ampliada para display
                                },
                      "id": 1
                    };
            var maintenanceids_arr = JSON.parse( req.get( url, JSON.stringify( jdata ) ) ).result;
            return maintenanceids_arr;
        }
        catch (error) {
            return { "error": "Problema al encontrar el/los mantenimiento/s: " + error };
        }
    }
}

// --- NUEVA FUNCIÓN: create_maintenance ---
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
 * @returns {Object|string} - Resultado de la API o mensaje de error.
 */
function create_maintenance(url, token, maintenance_name, maintenance_active_since, maintenance_active_till, maintenance_type, timeperiod_startdate, timeperiod_period, hostids, groupids) {
    // Validación básica de parámetros requeridos
    if (!url || !token || !maintenance_name || typeof maintenance_active_since !== 'number' || typeof maintenance_active_till !== 'number' || typeof timeperiod_startdate !== 'number' || typeof timeperiod_period !== 'number') {
        return {"error": "Parámetros inválidos para create_maintenance."};
    }

    // Asegurar valores por defecto
    if (typeof maintenance_type === 'undefined' || maintenance_type === null) {
        maintenance_type = 0; // Normal por defecto
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

        var response = req.get(url, JSON.stringify(jdata));

        // Intentar parsear la respuesta
        var parsedResponse = JSON.parse(response);

        // Verificar si la API devolvió un error
        if (parsedResponse.error) {
            return {"error": "Error de la API Zabbix en create_maintenance: " + JSON.stringify(parsedResponse.error)};
        }

        // Devolver el resultado exitoso
        return parsedResponse.result;

    } catch (error) {
        return {"error": "Error al crear el mantenimiento: " + error};
    }
}


// --- FUNCIÓN MODIFICADA: upd_maintenance ---
// Corrección: timeperiods debe ser un array de objetos, no un solo objeto.
function upd_maintenance(url, token, maintenance_id, timeperiod_startdate, timeperiod_period, hostids, groupids){
    //Actualizamos el mantenimiento cuya id es maintenance_id
    if (maintenance_id == "null" || !maintenance_id) {
        return {"error": "ID de mantenimiento inválida para actualizar."};
    } else {
        try {
            var req = new HttpRequest();
            req.addHeader('Content-Type: application/json');
            req.addHeader('Authorization: Bearer ' + token);
            // CORRECCIÓN: timeperiods ahora es un array
            var jdata = { "jsonrpc": "2.0",
                      "method": "maintenance.update",
                      "params": {
                          "maintenanceid": maintenance_id,
                          "timeperiods": [{
                              "start_date": timeperiod_startdate,
                              "period": timeperiod_period
                          }]
                      },
                      "id": 1
                    };
            // Agregamos a la solicitud los hosts que queremos poner en mantenimiento
            if (hostids && Array.isArray(hostids) && hostids.length > 0) {
                jdata.params.hosts = hostids;
            }
            // Agregamos a la solicitud los hostgroups que queremos poner en mantenimiento
            if (groupids && Array.isArray(groupids) && groupids.length > 0) {
                jdata.params.groups = groupids;
            }
            var response = req.get(url, JSON.stringify( jdata ) );
            var result = JSON.parse(response);
            if (result.error) {
               return {"error": "API Error: " + JSON.stringify(result.error)};
            }
            return result.result;
        }
        catch (error) {
            return {"error": "Problema al actualizar el mantenimiento: " + error};
        }
    }
}

// --- FUNCIÓN PARA DISPLAY ---
// Obtiene detalles del mantenimiento
function display_maintenance(url, token, maintenance_name) {
    if (!maintenance_name || maintenance_name.length === 0) {
        return {"error": "Nombre de mantenimiento inválido para mostrar."};
    }
    var maintenance_info = get_maintenance_id(url, token, maintenance_name);
    if (maintenance_info && Array.isArray(maintenance_info) && maintenance_info.length > 0) {
        return maintenance_info[0]; // Devuelve el primer match con toda la info
    } else if (maintenance_info && maintenance_info.error) {
        return maintenance_info; // Devuelve el objeto de error si lo hay
    } else {
        return {"error": "Mantenimiento no encontrado: " + maintenance_name};
    }
}


// --- LÓGICA PRINCIPAL: Leer 'action' y llamar a la función correspondiente ---

try {
    var input = JSON.parse(value);

    var action = input.action; // <-- Campo clave del nuevo flujo
    var url = input.zbx_url;
    var token = input.zbx_apitoken;
    var maintenanceName = input.maintenance_name;

    var result;

    switch(action) {
        case 'create':
            var hostnames_arr = parse_names(input.hostnames || "");
            var groupnames_arr = parse_names(input.groupnames || "");
            var hostIds = get_host_id(url, token, hostnames_arr);
            var groupIds = get_group_id(url, token, groupnames_arr);

            // Validar que hostIds/groupIds no contengan errores antes de llamar a create
            if (hostIds.error) {
                 result = hostIds; // Devuelve el error de get_host_id
            } else if (groupIds.error) {
                 result = groupIds; // Devuelve el error de get_group_id
            } else {
                 result = create_maintenance(
                     url,
                     token,
                     maintenanceName,
                     input.maintenance_active_since,
                     input.maintenance_active_till,
                     input.maintenance_type,
                     input.timeperiod_startdate,
                     input.timeperiod_period,
                     hostIds,
                     groupIds
                 );
            }
            break;
        case 'update':
            var hostnames_arr = parse_names(input.hostnames || "");
            var groupnames_arr = parse_names(input.groupnames || "");
            var hostIds = get_host_id(url, token, hostnames_arr);
            var groupIds = get_group_id(url, token, groupnames_arr);
            var maintenanceDetails = get_maintenance_id(url, token, maintenanceName);
            var maintenanceId = null;
            if (Array.isArray(maintenanceDetails) && maintenanceDetails.length > 0) {
                maintenanceId = maintenanceDetails[0].maintenanceid;
            }

            if (!maintenanceId) {
                 result = {"error": "Mantenimiento no encontrado para actualizar: " + maintenanceName};
            } else if (hostIds.error) {
                 result = hostIds; // Devuelve el error de get_host_id
            } else if (groupIds.error) {
                 result = groupIds; // Devuelve el error de get_group_id
            } else {
                 result = upd_maintenance(
                     url,
                     token,
                     maintenanceId,
                     input.timeperiod_startdate,
                     input.timeperiod_period,
                     hostIds,
                     groupIds
                 );
            }
            break;
        case 'display':
            result = display_maintenance(url, token, maintenanceName);
            break;
        // --- AÑADIR OTROS CASES AQUÍ ---
        // case 'delete':
        //     // Lógica para delete
        //     break;
        // case 'list':
        //     // Lógica para list
        //     break;
        default:
            result = {"error": "Acción desconocida recibida: " + action};
    }

    // Devolver el resultado como string JSON
    print(JSON.stringify(result));

} catch (e) {
    print(JSON.stringify({"error": "Error procesando la solicitud en el handler: " + e.message}));
}

// Fin del script
