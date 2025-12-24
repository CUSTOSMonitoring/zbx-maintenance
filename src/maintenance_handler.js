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
        return "Problema al encontrar el/los host/s: " + error;
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
        return "Problema al encontrar el/los hostgroup/s: " + error;
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
        return "Problema al encontrar el/los mantenimiento/s: " + error;
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
        return "Problema al encontrar el/los mantenimiento/s: " + error;
    }
}


//MaintenanceInfo[0].hosts = extractIds(MaintenanceInfo[0].hosts, "name");
function format_display(maintenance_info) {
    maintenance_info[0].hostgroups = extractIds(maintenance_info[0].hostgroups, "name");
    maintenance_info[0].hosts = extractIds(maintenance_info[0].hosts, "name");
    return maintenance_info;
}

// Actualizamos un mantenimiento existente en Zabbix
function upd_maintenance(url, token, maintenance_id, timeperiod_startdate, timeperiod_period, hostids, groupids) {
    // Validación: maintenance_id debe ser un valor válido (no null, undefined, vacío)
    if (maintenance_id == null || maintenance_id === "") {
        return null;
    }

    // Validación: timeperiod_period debe ser un número positivo
    if (typeof timeperiod_period !== 'number' || timeperiod_period <= 0) {
        return null;
    }

    // Validación: hostids y groupids deben ser un array
    // Importante: Si le llega un array vacio, estamos indicando que vamos a quitar los hosts o los grupos del mantenimiento dependiendo del array
    var hasHosts = Array.isArray(hostids) //&& hostids.length > 0;
    var hasGroups = Array.isArray(groupids) //&& groupids.length > 0;

    // Usamos timeperiod_startdate si está especificado, sino usamos NOW
    if (
        timeperiod_startdate != null &&
        !isNaN(timeperiod_startdate)
    ) {
        start_date = Math.floor(timeperiod_startdate);
    } else {
        start_date = Math.floor(Date.now() / 1000);
    }


    try {
        req = new HttpRequest();
        req.addHeader('Content-Type: application/json');
        req.addHeader('Authorization: Bearer ' + token);

        // Construimos el cuerpo de la solicitud
        jdata = {
            "jsonrpc": "2.0",
            "method": "maintenance.update",
            "params": {
                "maintenanceid": maintenance_id,
                "timeperiods": [
                    {
                        "start_date": start_date,
                        "period": timeperiod_period
                    }
                ]
            },
            "id": 1
        };

        // Solo agregamos hosts si se proporcionaron
        if (hasHosts) {
            jdata.params.hosts = hostids;
        }

        // Solo agregamos groups si se proporcionaron
        if (hasGroups) {
            jdata.params.groups = groupids;
        }

        // Enviamos la solicitud
        var response = req.get(url, JSON.stringify(jdata));
        var maintenanceids_arr = JSON.parse(response).result;

        return maintenanceids_arr;

    } catch (error) {
        return "Problema al actualizar el mantenimiento: " + error;
    }
}



var input = JSON.parse(value);

var ZbxURL = input.zbx_url;
var ZbxApiToken = input.zbx_apitoken;
var MaintenanceName = input.maintenance_name;
var TimePeriodStartDate = input.timeperiod_startdate;
var TimePeriodPeriod = parseInt(input.timeperiod_period);
var Hostnames = input.hostnames;
var Groupnames = input.groupnames;

var RunMode = input.run_mode || "update_maintenance";

var MaintenanceIDs = get_maintenance_id(ZbxURL, ZbxApiToken, MaintenanceName);
MaintenanceIDs = extractIds(MaintenanceIDs, "maintenanceid");

if (RunMode == "display_maintenance") {
    var MaintenanceInfo = display_maintenance(ZbxURL, ZbxApiToken, MaintenanceIDs[0])
    MaintenanceInfo = format_display(MaintenanceInfo)
    return JSON.stringify(MaintenanceInfo);
}

var Hostnames_arr = parse_names(Hostnames);
var HostIds = get_host_id(ZbxURL, ZbxApiToken, Hostnames_arr);

var Groupnames_arr = parse_names(Groupnames);
var GroupIds = get_group_id(ZbxURL, ZbxApiToken, Groupnames_arr);

var MaintenanceRes = upd_maintenance(ZbxURL, ZbxApiToken, MaintenanceIDs[0], TimePeriodStartDate, TimePeriodPeriod, HostIds, GroupIds);
res = MaintenanceRes;


return JSON.stringify(res);
//return res;
