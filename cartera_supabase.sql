-- CARTERA MULTIMONEDA — SCRIPT COMPLETO PARA SUPABASE (SQL Editor > New query > Run)
-- =====================================================================
-- CARTERA MULTIMONEDA v2 (PostgreSQL 13+)
-- Correcciones sobre v1:
--  * Operación de cabecera que agrupa movimientos (arbitraje atómico y anulable)
--  * Tipos ANULACION_ENTRADA / ANULACION_SALIDA (contra-asiento)
--  * Signo por tipo + CHECK saldo_nuevo = saldo_anterior ± monto
--  * Bloqueo FOR UPDATE (evita saldos corruptos con 2 cajeros a la vez)
--  * Redondeo según decimales de la moneda (PYG sin decimales)
--  * Movimientos y operaciones inmutables (UPDATE/DELETE/TRUNCATE bloqueados)
--  * saldo_actual solo modificable vía funciones
--  * Nueva moneda => se crea subcuenta para todos los clientes existentes
--  * TIMESTAMPTZ y NOT NULL donde faltaban
-- =====================================================================

-- 1. Catálogo de Monedas
CREATE TABLE monedas (
    codigo    VARCHAR(3) PRIMARY KEY,
    nombre    VARCHAR(50) NOT NULL,
    simbolo   VARCHAR(5)  NOT NULL,
    decimales INT NOT NULL DEFAULT 2 CHECK (decimales BETWEEN 0 AND 4)
);

-- 2. Clientes
CREATE TABLE clientes (
    id              SERIAL PRIMARY KEY,
    tipo_persona    VARCHAR(10) NOT NULL CHECK (tipo_persona IN ('FISICA','JURIDICA')),
    nombre_completo VARCHAR(150) NOT NULL,
    documento       VARCHAR(30) UNIQUE NOT NULL,  -- CI, RUC o Pasaporte
    telefono        VARCHAR(30),
    direccion       TEXT,
    observaciones   TEXT,
    activo          BOOLEAN NOT NULL DEFAULT TRUE,
    fecha_registro  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 3. Cartera (una fila por cliente y moneda)
--    (+) la casa le debe al cliente | (-) el cliente le debe a la casa
CREATE TABLE cartera_cliente (
    id                   SERIAL PRIMARY KEY,
    cliente_id           INT NOT NULL REFERENCES clientes(id) ON DELETE RESTRICT,
    moneda_codigo        VARCHAR(3) NOT NULL REFERENCES monedas(codigo) ON DELETE RESTRICT,
    saldo_actual         NUMERIC(18,4) NOT NULL DEFAULT 0,
    ultima_actualizacion TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (cliente_id, moneda_codigo)
);

-- 4. Signo de cada tipo de operación
CREATE OR REPLACE FUNCTION fn_signo(p_tipo TEXT) RETURNS SMALLINT
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE
        WHEN p_tipo IN ('DEPOSITO_CLIENTE','COBRO_A_CLIENTE','ARBITRAJE_ENTRADA','ANULACION_ENTRADA') THEN 1
        WHEN p_tipo IN ('PAGO_A_CLIENTE','ENTREGA_A_CLIENTE','ARBITRAJE_SALIDA','ANULACION_SALIDA') THEN -1
    END::SMALLINT
$$;

-- 5. Operación (cabecera: agrupa 1..n movimientos)
CREATE TABLE operaciones (
    id                   BIGSERIAL PRIMARY KEY,
    cliente_id           INT NOT NULL REFERENCES clientes(id) ON DELETE RESTRICT,
    tipo                 VARCHAR(10) NOT NULL CHECK (tipo IN ('SIMPLE','ARBITRAJE','ANULACION')),
    operacion_anulada_id BIGINT UNIQUE REFERENCES operaciones(id),  -- UNIQUE: no se anula dos veces
    concepto             TEXT NOT NULL,
    usuario_registro     VARCHAR(50) NOT NULL,
    fecha                TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK ((tipo = 'ANULACION') = (operacion_anulada_id IS NOT NULL))
);

-- 6. Movimientos (libro mayor / extracto)
CREATE TABLE movimientos_cartera (
    id               BIGSERIAL PRIMARY KEY,
    operacion_id     BIGINT NOT NULL REFERENCES operaciones(id) ON DELETE RESTRICT,
    cartera_id       INT NOT NULL REFERENCES cartera_cliente(id) ON DELETE RESTRICT,
    fecha_movimiento TIMESTAMPTZ NOT NULL DEFAULT now(),
    tipo_operacion   VARCHAR(20) NOT NULL CHECK (fn_signo(tipo_operacion) IS NOT NULL),
    monto            NUMERIC(18,4) NOT NULL CHECK (monto > 0),
    tasa_cambio      NUMERIC(18,6),
    saldo_anterior   NUMERIC(18,4) NOT NULL,
    saldo_nuevo      NUMERIC(18,4) NOT NULL,
    metodo_pago      VARCHAR(30) NOT NULL DEFAULT 'EFECTIVO'
                     CHECK (metodo_pago IN ('EFECTIVO','TRANSFERENCIA','CHEQUE','INTERNO')),
    comprobante_ref  VARCHAR(50),
    concepto         TEXT NOT NULL,
    usuario_registro VARCHAR(50) NOT NULL,
    CHECK (saldo_nuevo = saldo_anterior + fn_signo(tipo_operacion) * monto)
);
CREATE INDEX idx_mov_cartera_fecha ON movimientos_cartera (cartera_id, fecha_movimiento);
CREATE INDEX idx_mov_operacion     ON movimientos_cartera (operacion_id);

-- =====================================================================
-- TRIGGERS
-- =====================================================================

-- 7. Nuevo cliente => 1 subcuenta por cada moneda
CREATE OR REPLACE FUNCTION crear_cartera_inicial() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO cartera_cliente (cliente_id, moneda_codigo)
    SELECT NEW.id, codigo FROM monedas;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_nuevo_cliente_cartera AFTER INSERT ON clientes
FOR EACH ROW EXECUTE FUNCTION crear_cartera_inicial();

-- 8. Nueva moneda => subcuenta para todos los clientes existentes
CREATE OR REPLACE FUNCTION crear_cartera_nueva_moneda() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO cartera_cliente (cliente_id, moneda_codigo)
    SELECT id, NEW.codigo FROM clientes
    ON CONFLICT (cliente_id, moneda_codigo) DO NOTHING;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_nueva_moneda_cartera AFTER INSERT ON monedas
FOR EACH ROW EXECUTE FUNCTION crear_cartera_nueva_moneda();

-- 9. Inmutabilidad de movimientos y operaciones
CREATE OR REPLACE FUNCTION fn_bloquear_cambios() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'Registro inmutable (%). Use anular_operacion().', TG_TABLE_NAME;
END $$;
CREATE TRIGGER trg_mov_inmutable BEFORE UPDATE OR DELETE ON movimientos_cartera
FOR EACH ROW EXECUTE FUNCTION fn_bloquear_cambios();
CREATE TRIGGER trg_mov_no_truncate BEFORE TRUNCATE ON movimientos_cartera
FOR EACH STATEMENT EXECUTE FUNCTION fn_bloquear_cambios();
CREATE TRIGGER trg_op_inmutable BEFORE UPDATE OR DELETE ON operaciones
FOR EACH ROW EXECUTE FUNCTION fn_bloquear_cambios();
CREATE TRIGGER trg_op_no_truncate BEFORE TRUNCATE ON operaciones
FOR EACH STATEMENT EXECUTE FUNCTION fn_bloquear_cambios();

-- 10. saldo_actual solo cambia desde registrar_movimiento()
CREATE OR REPLACE FUNCTION fn_proteger_saldo() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'INSERT' AND NEW.saldo_actual <> 0 THEN
        RAISE EXCEPTION 'Una subcuenta nueva debe iniciar en 0';
    END IF;
    IF TG_OP = 'UPDATE'
       AND (NEW.saldo_actual IS DISTINCT FROM OLD.saldo_actual
            OR NEW.cliente_id <> OLD.cliente_id
            OR NEW.moneda_codigo <> OLD.moneda_codigo)
       AND coalesce(current_setting('app.via_funcion', true), 'off') <> 'on' THEN
        RAISE EXCEPTION 'El saldo solo se modifica registrando movimientos';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_proteger_saldo BEFORE INSERT OR UPDATE ON cartera_cliente
FOR EACH ROW EXECUTE FUNCTION fn_proteger_saldo();

-- =====================================================================
-- FUNCIONES DE OPERACIÓN (la app SOLO usa estas)
-- =====================================================================

-- 11. Núcleo: un movimiento con bloqueo y redondeo
CREATE OR REPLACE FUNCTION registrar_movimiento(
    p_operacion_id BIGINT, p_cliente_id INT, p_moneda VARCHAR, p_tipo VARCHAR,
    p_monto NUMERIC, p_usuario VARCHAR, p_concepto TEXT,
    p_tasa NUMERIC DEFAULT NULL, p_metodo VARCHAR DEFAULT 'EFECTIVO',
    p_comprobante VARCHAR DEFAULT NULL
) RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE
    v_cart  cartera_cliente%ROWTYPE;
    v_dec   INT;
    v_monto NUMERIC;
    v_nuevo NUMERIC;
    v_id    BIGINT;
BEGIN
    IF fn_signo(p_tipo) IS NULL THEN
        RAISE EXCEPTION 'Tipo de operación inválido: %', p_tipo;
    END IF;
    SELECT decimales INTO v_dec FROM monedas WHERE codigo = p_moneda;
    IF NOT FOUND THEN RAISE EXCEPTION 'Moneda inexistente: %', p_moneda; END IF;

    v_monto := round(p_monto, v_dec);
    IF v_monto IS NULL OR v_monto <= 0 THEN
        RAISE EXCEPTION 'Monto inválido tras redondeo: %', p_monto;
    END IF;

    SELECT * INTO v_cart FROM cartera_cliente
    WHERE cliente_id = p_cliente_id AND moneda_codigo = p_moneda
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Cliente % sin subcuenta %', p_cliente_id, p_moneda;
    END IF;

    v_nuevo := v_cart.saldo_actual + fn_signo(p_tipo) * v_monto;

    INSERT INTO movimientos_cartera (operacion_id, cartera_id, tipo_operacion, monto,
        tasa_cambio, saldo_anterior, saldo_nuevo, metodo_pago, comprobante_ref,
        concepto, usuario_registro)
    VALUES (p_operacion_id, v_cart.id, p_tipo, v_monto, p_tasa,
        v_cart.saldo_actual, v_nuevo, p_metodo, p_comprobante, p_concepto, p_usuario)
    RETURNING id INTO v_id;

    PERFORM set_config('app.via_funcion', 'on', true);
    UPDATE cartera_cliente SET saldo_actual = v_nuevo, ultima_actualizacion = now()
    WHERE id = v_cart.id;
    PERFORM set_config('app.via_funcion', 'off', true);

    RETURN v_id;
END $$;

-- 12. Operación simple (depósito, pago, entrega, cobro)
CREATE OR REPLACE FUNCTION operar_simple(
    p_cliente_id INT, p_moneda VARCHAR, p_tipo VARCHAR, p_monto NUMERIC,
    p_usuario VARCHAR, p_concepto TEXT,
    p_metodo VARCHAR DEFAULT 'EFECTIVO', p_comprobante VARCHAR DEFAULT NULL
) RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE v_op BIGINT;
BEGIN
    IF p_tipo NOT IN ('DEPOSITO_CLIENTE','PAGO_A_CLIENTE','ENTREGA_A_CLIENTE','COBRO_A_CLIENTE') THEN
        RAISE EXCEPTION 'Tipo % no permitido en operación simple', p_tipo;
    END IF;
    IF NOT (SELECT activo FROM clientes WHERE id = p_cliente_id) THEN
        RAISE EXCEPTION 'Cliente inactivo';
    END IF;
    INSERT INTO operaciones (cliente_id, tipo, concepto, usuario_registro)
    VALUES (p_cliente_id, 'SIMPLE', p_concepto, p_usuario) RETURNING id INTO v_op;

    PERFORM registrar_movimiento(v_op, p_cliente_id, p_moneda, p_tipo, p_monto,
                                 p_usuario, p_concepto, NULL, p_metodo, p_comprobante);
    RETURN v_op;
END $$;

-- 13. Arbitraje / cruce (atómico: todo o nada)
--     p_modo 'MULTIPLICAR': destino = origen * tasa  (USD→BRL 5.45, USD→PYG 7300)
--     p_modo 'DIVIDIR'    : destino = origen / tasa  (BRL→USD 5.45, PYG→USD 7300)
--     p_pagar_efectivo    : agrega PAGO_A_CLIENTE en la moneda destino
CREATE OR REPLACE FUNCTION operar_arbitraje(
    p_cliente_id INT, p_moneda_origen VARCHAR, p_moneda_destino VARCHAR,
    p_monto_origen NUMERIC, p_tasa NUMERIC, p_modo VARCHAR,
    p_usuario VARCHAR, p_concepto TEXT,
    p_pagar_efectivo BOOLEAN DEFAULT FALSE,
    p_permitir_negativo BOOLEAN DEFAULT FALSE,
    p_metodo VARCHAR DEFAULT 'EFECTIVO', p_comprobante VARCHAR DEFAULT NULL
) RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE
    v_op      BIGINT;
    v_saldo   NUMERIC;
    v_destino NUMERIC;
BEGIN
    IF p_moneda_origen = p_moneda_destino THEN
        RAISE EXCEPTION 'Origen y destino deben ser distintos';
    END IF;
    IF p_tasa IS NULL OR p_tasa <= 0 THEN RAISE EXCEPTION 'Tasa inválida'; END IF;
    IF p_modo NOT IN ('MULTIPLICAR','DIVIDIR') THEN RAISE EXCEPTION 'Modo inválido'; END IF;

    SELECT saldo_actual INTO v_saldo FROM cartera_cliente
    WHERE cliente_id = p_cliente_id AND moneda_codigo = p_moneda_origen FOR UPDATE;
    IF NOT p_permitir_negativo AND v_saldo < p_monto_origen THEN
        RAISE EXCEPTION 'Saldo % insuficiente: % disponible', p_moneda_origen, v_saldo;
    END IF;

    v_destino := CASE p_modo WHEN 'MULTIPLICAR' THEN p_monto_origen * p_tasa
                             ELSE p_monto_origen / p_tasa END;

    INSERT INTO operaciones (cliente_id, tipo, concepto, usuario_registro)
    VALUES (p_cliente_id, 'ARBITRAJE', p_concepto, p_usuario) RETURNING id INTO v_op;

    PERFORM registrar_movimiento(v_op, p_cliente_id, p_moneda_origen, 'ARBITRAJE_SALIDA',
        p_monto_origen, p_usuario, p_concepto, p_tasa, 'INTERNO');
    PERFORM registrar_movimiento(v_op, p_cliente_id, p_moneda_destino, 'ARBITRAJE_ENTRADA',
        v_destino, p_usuario, p_concepto, p_tasa, 'INTERNO');
    IF p_pagar_efectivo THEN
        PERFORM registrar_movimiento(v_op, p_cliente_id, p_moneda_destino, 'PAGO_A_CLIENTE',
            v_destino, p_usuario, p_concepto, NULL, p_metodo, p_comprobante);
    END IF;
    RETURN v_op;
END $$;

-- 14. Anulación (contra-asiento de TODA la operación)
CREATE OR REPLACE FUNCTION anular_operacion(
    p_operacion_id BIGINT, p_usuario VARCHAR, p_motivo TEXT
) RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE
    v_orig operaciones%ROWTYPE;
    v_op   BIGINT;
    r      RECORD;
BEGIN
    IF coalesce(trim(p_motivo), '') = '' THEN RAISE EXCEPTION 'Motivo obligatorio'; END IF;

    SELECT * INTO v_orig FROM operaciones WHERE id = p_operacion_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Operación % inexistente', p_operacion_id; END IF;
    IF v_orig.tipo = 'ANULACION' THEN RAISE EXCEPTION 'No se anula una anulación'; END IF;
    IF EXISTS (SELECT 1 FROM operaciones WHERE operacion_anulada_id = p_operacion_id) THEN
        RAISE EXCEPTION 'Operación % ya anulada', p_operacion_id;
    END IF;

    INSERT INTO operaciones (cliente_id, tipo, operacion_anulada_id, concepto, usuario_registro)
    VALUES (v_orig.cliente_id, 'ANULACION', p_operacion_id,
            'ANULA OP #' || p_operacion_id || ': ' || p_motivo, p_usuario)
    RETURNING id INTO v_op;

    FOR r IN
        SELECT m.*, c.moneda_codigo FROM movimientos_cartera m
        JOIN cartera_cliente c ON c.id = m.cartera_id
        WHERE m.operacion_id = p_operacion_id ORDER BY m.id DESC
    LOOP
        PERFORM registrar_movimiento(v_op, v_orig.cliente_id, r.moneda_codigo,
            CASE WHEN fn_signo(r.tipo_operacion) > 0 THEN 'ANULACION_SALIDA'
                 ELSE 'ANULACION_ENTRADA' END,
            r.monto, p_usuario, 'ANULA MOV #' || r.id || ': ' || p_motivo,
            r.tasa_cambio, 'INTERNO');
    END LOOP;
    RETURN v_op;
END $$;

-- =====================================================================
-- VISTAS
-- =====================================================================

-- 15. Ficha de cartera
CREATE OR REPLACE VIEW v_ficha_cartera AS
SELECT c.id AS cliente_id, c.nombre_completo, c.documento, c.telefono,
       m.codigo, m.nombre AS moneda, m.simbolo, m.decimales, cc.saldo_actual,
       CASE WHEN cc.saldo_actual > 0 THEN 'POR_PAGAR_AL_CLIENTE'
            WHEN cc.saldo_actual < 0 THEN 'POR_COBRAR_AL_CLIENTE'
            ELSE 'SALDADO' END AS estado,
       cc.ultima_actualizacion
FROM cartera_cliente cc
JOIN clientes c ON c.id = cc.cliente_id
JOIN monedas  m ON m.codigo = cc.moneda_codigo;

-- 16. Extracto con indicador de anulación
CREATE OR REPLACE VIEW v_extracto AS
SELECT cc.cliente_id, cc.moneda_codigo, mv.id AS movimiento_id, mv.operacion_id,
       mv.fecha_movimiento, mv.tipo_operacion,
       fn_signo(mv.tipo_operacion) * mv.monto AS importe,
       mv.saldo_anterior, mv.saldo_nuevo, mv.tasa_cambio, mv.metodo_pago,
       mv.comprobante_ref, mv.concepto, mv.usuario_registro,
       EXISTS (SELECT 1 FROM operaciones a WHERE a.operacion_anulada_id = mv.operacion_id) AS anulado
FROM movimientos_cartera mv
JOIN cartera_cliente cc ON cc.id = mv.cartera_id;

-- 17. Auditoría: debe devolver 0 filas
CREATE OR REPLACE VIEW v_auditoria_descuadres AS
SELECT cc.id AS cartera_id, cc.cliente_id, cc.moneda_codigo, cc.saldo_actual,
       coalesce(sum(fn_signo(mv.tipo_operacion) * mv.monto), 0) AS saldo_calculado
FROM cartera_cliente cc
LEFT JOIN movimientos_cartera mv ON mv.cartera_id = cc.id
GROUP BY cc.id
HAVING cc.saldo_actual <> coalesce(sum(fn_signo(mv.tipo_operacion) * mv.monto), 0);

-- =====================================================================
-- DATOS INICIALES
-- =====================================================================
INSERT INTO monedas (codigo, nombre, simbolo, decimales) VALUES
('USD', 'Dólar Estadounidense', '$',   2),
('EUR', 'Euro',                 '€',   2),
('BRL', 'Real Brasileño',       'R$',  2),
('PYG', 'Guaraní Paraguayo',    'Gs.', 0),
('ARS', 'Peso Argentino',       '$',   2);

-- =====================================================================
-- EJEMPLOS DE USO
-- =====================================================================
-- SELECT operar_simple(1, 'USD', 'DEPOSITO_CLIENTE', 10000, 'cajero1', 'Depósito inicial');
-- SELECT operar_arbitraje(1, 'USD', 'BRL', 10000, 5.45, 'MULTIPLICAR', 'cajero1',
--                         'Retiro en reales', p_pagar_efectivo => TRUE);
-- SELECT anular_operacion(2, 'supervisor', 'Tasa mal cargada');
-- SELECT * FROM v_ficha_cartera WHERE cliente_id = 1;
-- SELECT * FROM v_auditoria_descuadres;  -- 0 filas = todo cuadra
--
-- SEGURIDAD: la app debe conectarse con un rol SIN permisos de
-- INSERT/UPDATE/DELETE sobre las tablas, solo EXECUTE sobre las funciones
-- (declararlas SECURITY DEFINER con dueño administrador).

-- =====================================================================
-- CAPA SUPABASE: usuarios, roles, API segura, RLS y vistas de reportes
-- =====================================================================

-- 18. Perfiles de usuario (email = el de Supabase Auth)
CREATE TABLE perfiles (
    email  TEXT PRIMARY KEY CHECK (email = lower(email)),
    nombre TEXT NOT NULL,
    rol    VARCHAR(10) NOT NULL CHECK (rol IN ('CAJERO','SUPERVISOR','ADMIN')),
    activo BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE OR REPLACE FUNCTION fn_perfil_actual(p_roles TEXT[] DEFAULT NULL) RETURNS perfiles
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v perfiles;
BEGIN
    SELECT * INTO v FROM perfiles WHERE email = lower(auth.jwt() ->> 'email') AND activo;
    IF NOT FOUND THEN RAISE EXCEPTION 'Usuario sin perfil habilitado'; END IF;
    IF p_roles IS NOT NULL AND NOT (v.rol = ANY (p_roles)) THEN
        RAISE EXCEPTION 'Permiso insuficiente (rol %)', v.rol;
    END IF;
    RETURN v;
END $$;

CREATE OR REPLACE FUNCTION fn_es_usuario() RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    SELECT EXISTS (SELECT 1 FROM perfiles WHERE email = lower(auth.jwt() ->> 'email') AND activo)
$$;

-- 19. Vistas de reportes
CREATE OR REPLACE VIEW v_resumen_dia AS
SELECT (mv.fecha_movimiento AT TIME ZONE 'America/Asuncion')::date AS fecha,
       cc.moneda_codigo, mv.tipo_operacion, mv.metodo_pago,
       count(*) AS cantidad, sum(mv.monto) AS total
FROM movimientos_cartera mv
JOIN cartera_cliente cc ON cc.id = mv.cartera_id
GROUP BY 1, 2, 3, 4;

CREATE OR REPLACE VIEW v_posicion_monedas AS
SELECT m.codigo, m.simbolo, m.decimales,
       coalesce(sum(cc.saldo_actual) FILTER (WHERE cc.saldo_actual > 0), 0) AS por_pagar,
       coalesce(sum(cc.saldo_actual) FILTER (WHERE cc.saldo_actual < 0), 0) AS por_cobrar,
       coalesce(sum(cc.saldo_actual), 0) AS neto,
       count(*) FILTER (WHERE cc.saldo_actual <> 0) AS cuentas_con_saldo
FROM monedas m
LEFT JOIN cartera_cliente cc ON cc.moneda_codigo = m.codigo
GROUP BY m.codigo, m.simbolo, m.decimales;

-- 20. API pública (lo único que la app puede ejecutar)
CREATE OR REPLACE FUNCTION api_mi_perfil()
RETURNS TABLE (email TEXT, nombre TEXT, rol TEXT)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v perfiles;
BEGIN
    v := fn_perfil_actual();
    RETURN QUERY SELECT v.email, v.nombre, v.rol::TEXT;
END $$;

CREATE OR REPLACE FUNCTION api_crear_cliente(
    p_tipo TEXT, p_nombre TEXT, p_documento TEXT,
    p_telefono TEXT DEFAULT NULL, p_direccion TEXT DEFAULT NULL, p_observaciones TEXT DEFAULT NULL
) RETURNS INT LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_id INT;
BEGIN
    PERFORM fn_perfil_actual();
    IF coalesce(trim(p_nombre), '') = '' OR coalesce(trim(p_documento), '') = '' THEN
        RAISE EXCEPTION 'Nombre y documento son obligatorios';
    END IF;
    INSERT INTO clientes (tipo_persona, nombre_completo, documento, telefono, direccion, observaciones)
    VALUES (upper(p_tipo), trim(p_nombre), upper(trim(p_documento)),
            nullif(trim(p_telefono), ''), nullif(trim(p_direccion), ''), nullif(trim(p_observaciones), ''))
    RETURNING id INTO v_id;
    RETURN v_id;
EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'Ya existe un cliente con documento %', p_documento;
END $$;

CREATE OR REPLACE FUNCTION api_actualizar_cliente(
    p_id INT, p_nombre TEXT, p_telefono TEXT, p_direccion TEXT, p_observaciones TEXT, p_activo BOOLEAN
) RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v perfiles; v_act BOOLEAN;
BEGIN
    v := fn_perfil_actual();
    SELECT activo INTO v_act FROM clientes WHERE id = p_id;
    IF NOT FOUND THEN RAISE EXCEPTION 'Cliente inexistente'; END IF;
    IF p_activo IS DISTINCT FROM v_act AND v.rol = 'CAJERO' THEN
        RAISE EXCEPTION 'Solo SUPERVISOR o ADMIN activa/desactiva clientes';
    END IF;
    IF coalesce(trim(p_nombre), '') = '' THEN RAISE EXCEPTION 'Nombre obligatorio'; END IF;
    UPDATE clientes SET nombre_completo = trim(p_nombre),
        telefono = nullif(trim(p_telefono), ''), direccion = nullif(trim(p_direccion), ''),
        observaciones = nullif(trim(p_observaciones), ''), activo = coalesce(p_activo, v_act)
    WHERE id = p_id;
END $$;

CREATE OR REPLACE FUNCTION api_operar_simple(
    p_cliente_id INT, p_moneda TEXT, p_tipo TEXT, p_monto NUMERIC, p_concepto TEXT,
    p_metodo TEXT DEFAULT 'EFECTIVO', p_comprobante TEXT DEFAULT NULL
) RETURNS BIGINT LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v perfiles;
BEGIN
    v := fn_perfil_actual();
    IF coalesce(trim(p_concepto), '') = '' THEN RAISE EXCEPTION 'Concepto obligatorio'; END IF;
    RETURN operar_simple(p_cliente_id, p_moneda, p_tipo, p_monto, v.email, trim(p_concepto),
                         p_metodo, nullif(trim(p_comprobante), ''));
END $$;

CREATE OR REPLACE FUNCTION api_operar_arbitraje(
    p_cliente_id INT, p_moneda_origen TEXT, p_moneda_destino TEXT, p_monto_origen NUMERIC,
    p_tasa NUMERIC, p_modo TEXT, p_concepto TEXT,
    p_pagar_efectivo BOOLEAN DEFAULT FALSE, p_permitir_negativo BOOLEAN DEFAULT FALSE,
    p_metodo TEXT DEFAULT 'EFECTIVO', p_comprobante TEXT DEFAULT NULL
) RETURNS BIGINT LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v perfiles;
BEGIN
    v := fn_perfil_actual();
    IF p_permitir_negativo AND v.rol = 'CAJERO' THEN
        RAISE EXCEPTION 'Solo SUPERVISOR o ADMIN autoriza cruces con saldo negativo';
    END IF;
    IF coalesce(trim(p_concepto), '') = '' THEN RAISE EXCEPTION 'Concepto obligatorio'; END IF;
    RETURN operar_arbitraje(p_cliente_id, p_moneda_origen, p_moneda_destino, p_monto_origen,
        p_tasa, p_modo, v.email, trim(p_concepto), p_pagar_efectivo, p_permitir_negativo,
        p_metodo, nullif(trim(p_comprobante), ''));
END $$;

CREATE OR REPLACE FUNCTION api_anular_operacion(p_operacion_id BIGINT, p_motivo TEXT)
RETURNS BIGINT LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v perfiles;
BEGIN
    v := fn_perfil_actual(ARRAY['SUPERVISOR','ADMIN']);
    RETURN anular_operacion(p_operacion_id, v.email, p_motivo);
END $$;

-- 21. Vistas con permisos del usuario que consulta
ALTER VIEW v_ficha_cartera        SET (security_invoker = true);
ALTER VIEW v_extracto             SET (security_invoker = true);
ALTER VIEW v_auditoria_descuadres SET (security_invoker = true);
ALTER VIEW v_resumen_dia          SET (security_invoker = true);
ALTER VIEW v_posicion_monedas     SET (security_invoker = true);

-- 22. RLS: solo lectura para usuarios con perfil activo
DO $$
DECLARE t TEXT;
BEGIN
    FOREACH t IN ARRAY ARRAY['monedas','clientes','cartera_cliente','operaciones','movimientos_cartera','perfiles'] LOOP
        EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
        EXECUTE format('CREATE POLICY lectura_usuarios ON %I FOR SELECT TO authenticated USING (fn_es_usuario())', t);
    END LOOP;
END $$;

-- 23. Permisos: nadie escribe directo en tablas; solo EXECUTE sobre api_*
REVOKE ALL ON ALL TABLES    IN SCHEMA public FROM anon, authenticated;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM anon, authenticated;
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC, anon, authenticated;

GRANT SELECT ON monedas, clientes, cartera_cliente, operaciones, movimientos_cartera, perfiles,
    v_ficha_cartera, v_extracto, v_auditoria_descuadres, v_resumen_dia, v_posicion_monedas
    TO authenticated;
GRANT EXECUTE ON FUNCTION fn_signo(TEXT), fn_es_usuario(), api_mi_perfil(),
    api_crear_cliente(TEXT, TEXT, TEXT, TEXT, TEXT, TEXT),
    api_actualizar_cliente(INT, TEXT, TEXT, TEXT, TEXT, BOOLEAN),
    api_operar_simple(INT, TEXT, TEXT, NUMERIC, TEXT, TEXT, TEXT),
    api_operar_arbitraje(INT, TEXT, TEXT, NUMERIC, NUMERIC, TEXT, TEXT, BOOLEAN, BOOLEAN, TEXT, TEXT),
    api_anular_operacion(BIGINT, TEXT)
    TO authenticated;

-- 24. PRIMER ADMINISTRADOR — reemplace el email por el que creó en Authentication > Users
-- INSERT INTO perfiles (email, nombre, rol) VALUES ('admin@sucasa.com.py', 'Administrador', 'ADMIN');
-- Más usuarios:
-- INSERT INTO perfiles (email, nombre, rol) VALUES ('cajero1@sucasa.com.py', 'Cajero 1', 'CAJERO');
