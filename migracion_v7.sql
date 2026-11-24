-- =====================================================================
-- CARTERA MULTIMONEDA — MIGRACIÓN v7: eliminar cliente, reiniciar sistema, datos demo
-- Ejecutar UNA vez después de migracion_v6.sql
-- =====================================================================

-- 1. Clientes eliminados con historial (quedan ocultos; el documento se puede reutilizar)
ALTER TABLE clientes ADD COLUMN IF NOT EXISTS eliminado BOOLEAN NOT NULL DEFAULT FALSE;
DROP INDEX IF EXISTS ux_clientes_empresa_doc;
CREATE UNIQUE INDEX ux_clientes_empresa_doc ON clientes (empresa_id, documento) WHERE NOT eliminado;

-- 2. La inmutabilidad admite solo el reinicio explícito de la propia empresa
CREATE OR REPLACE FUNCTION fn_bloquear_cambios() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        IF coalesce(current_setting('app.reset_empresa', true), '') = OLD.empresa_id::TEXT THEN
            RETURN OLD;
        END IF;
    END IF;
    RAISE EXCEPTION 'Registro inmutable (%). Use anular_operacion().', TG_TABLE_NAME;
END $$;

-- 3. Eliminar cliente
CREATE OR REPLACE FUNCTION api_eliminar_cliente(p_id INT)
RETURNS TEXT LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v perfiles; pend TEXT;
BEGIN
    v := fn_perfil_actual(ARRAY['ADMIN']);
    IF NOT EXISTS (SELECT 1 FROM clientes WHERE id = p_id AND empresa_id = v.empresa_id AND NOT eliminado) THEN
        RAISE EXCEPTION 'Cliente inexistente';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM operaciones WHERE cliente_id = p_id) THEN
        DELETE FROM cartera_cliente WHERE cliente_id = p_id;
        DELETE FROM clientes WHERE id = p_id;
        RETURN 'ELIMINADO';
    END IF;
    SELECT string_agg(moneda_codigo || ' ' || rtrim(rtrim(saldo_actual::TEXT, '0'), '.'), ', ')
    INTO pend FROM cartera_cliente WHERE cliente_id = p_id AND saldo_actual <> 0;
    IF pend IS NOT NULL THEN
        RAISE EXCEPTION 'No se puede eliminar: tiene saldos pendientes (%). Déjelos en cero primero.', pend;
    END IF;
    UPDATE clientes SET eliminado = TRUE, activo = FALSE WHERE id = p_id;
    RETURN 'ARCHIVADO';
END $$;

-- 4. Reiniciar el sistema de la empresa (borra clientes, operaciones y cotizaciones; conserva usuarios y datos de la casa)
CREATE OR REPLACE FUNCTION api_reiniciar_empresa(p_confirmacion TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v perfiles; n_cli INT; n_op INT; n_mov INT; n_cot INT;
BEGIN
    v := fn_perfil_actual(ARRAY['ADMIN']);
    IF upper(trim(coalesce(p_confirmacion, ''))) <> 'REINICIAR' THEN
        RAISE EXCEPTION 'Escriba REINICIAR para confirmar';
    END IF;
    PERFORM set_config('app.reset_empresa', v.empresa_id::TEXT, true);
    DELETE FROM movimientos_cartera WHERE empresa_id = v.empresa_id; GET DIAGNOSTICS n_mov = ROW_COUNT;
    DELETE FROM operaciones         WHERE empresa_id = v.empresa_id; GET DIAGNOSTICS n_op  = ROW_COUNT;
    DELETE FROM cartera_cliente     WHERE empresa_id = v.empresa_id;
    DELETE FROM clientes            WHERE empresa_id = v.empresa_id; GET DIAGNOSTICS n_cli = ROW_COUNT;
    DELETE FROM cotizaciones        WHERE empresa_id = v.empresa_id; GET DIAGNOSTICS n_cot = ROW_COUNT;
    PERFORM set_config('app.reset_empresa', '', true);
    RETURN jsonb_build_object('clientes', n_cli, 'operaciones', n_op, 'movimientos', n_mov, 'cotizaciones', n_cot);
END $$;

-- 5. Cargar datos de demostración
CREATE OR REPLACE FUNCTION api_cargar_demo()
RETURNS INT LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v perfiles; e INT; u TEXT; c INT[] := '{}'; idc INT; op BIGINT;
    nom TEXT[] := ARRAY['Importadora del Este S.A.','María González','Comercial Triple Frontera S.R.L.','Carlos Benítez',
                        'Agroganadera San Pedro S.A.','Lucía Fernández','Distribuidora Paraná S.A.','Jorge Duarte'];
    tip TEXT[] := ARRAY['JURIDICA','FISICA','JURIDICA','FISICA','JURIDICA','FISICA','JURIDICA','FISICA'];
    doc TEXT[] := ARRAY['DEMO-80012345','DEMO-4567890','DEMO-80098765','DEMO-3219876','DEMO-80055511','DEMO-5123456','DEMO-80077733','DEMO-2987654'];
    tel TEXT[] := ARRAY['0981 100 200','0982 300 400','0983 500 600','0984 700 800','0985 900 100','0986 200 300','0987 400 500','0991 600 700'];
    i INT;
BEGIN
    v := fn_perfil_actual(ARRAY['ADMIN']);
    e := v.empresa_id; u := v.email;
    IF EXISTS (SELECT 1 FROM clientes WHERE empresa_id = e AND documento LIKE 'DEMO-%' AND NOT eliminado) THEN
        RAISE EXCEPTION 'Los datos de demostración ya están cargados';
    END IF;

    INSERT INTO cotizaciones (empresa_id, moneda_codigo, compra, venta, usuario_registro) VALUES
        (e, 'USD', 7250, 7350, u), (e, 'EUR', 7850, 8100, u), (e, 'BRL', 1260, 1330, u), (e, 'ARS', 6, 7.5, u);

    FOR i IN 1 .. array_length(nom, 1) LOOP
        INSERT INTO clientes (empresa_id, tipo_persona, nombre_completo, documento, telefono, observaciones)
        VALUES (e, tip[i], nom[i], doc[i], tel[i], 'Cliente de demostración')
        RETURNING id INTO idc;
        c := c || idc;
    END LOOP;

    PERFORM operar_simple(c[1], 'USD', 'DEPOSITO_CLIENTE', 12500, u, 'Depósito en efectivo', 'EFECTIVO', NULL);
    PERFORM operar_simple(c[1], 'BRL', 'DEPOSITO_CLIENTE', 8400, u, 'Transferencia recibida', 'TRANSFERENCIA', 'TR-10021');
    PERFORM operar_simple(c[1], 'PYG', 'DEPOSITO_CLIENTE', 15000000, u, 'Depósito en guaraníes', 'EFECTIVO', NULL);
    PERFORM operar_simple(c[1], 'ARS', 'ENTREGA_A_CLIENTE', 450000, u, 'Adelanto en pesos', 'EFECTIVO', NULL);

    PERFORM operar_simple(c[2], 'USD', 'DEPOSITO_CLIENTE', 3000, u, 'Ahorro en dólares', 'EFECTIVO', NULL);
    PERFORM operar_arbitraje(c[2], 'USD', 'PYG', 1000, 7250, 'MULTIPLICAR', u, 'Venta de dólares', TRUE, FALSE, 'EFECTIVO', NULL);

    PERFORM operar_simple(c[3], 'BRL', 'DEPOSITO_CLIENTE', 25000, u, 'Depósito de reales', 'TRANSFERENCIA', 'TR-10022');
    PERFORM operar_simple(c[3], 'USD', 'ENTREGA_A_CLIENTE', 5000, u, 'Adelanto para importación', 'TRANSFERENCIA', 'TR-10023');

    PERFORM operar_simple(c[4], 'EUR', 'DEPOSITO_CLIENTE', 2000, u, 'Depósito en euros', 'EFECTIVO', NULL);
    PERFORM operar_simple(c[4], 'EUR', 'PAGO_A_CLIENTE', 500, u, 'Retiro parcial', 'EFECTIVO', NULL);

    PERFORM operar_simple(c[5], 'PYG', 'DEPOSITO_CLIENTE', 85000000, u, 'Venta de ganado', 'CHEQUE', 'CH-55021');
    PERFORM operar_arbitraje(c[5], 'PYG', 'USD', 14700000, 7350, 'DIVIDIR', u, 'Compra de dólares', FALSE, FALSE, 'EFECTIVO', NULL);

    PERFORM operar_simple(c[6], 'PYG', 'ENTREGA_A_CLIENTE', 2500000, u, 'Préstamo de corto plazo', 'EFECTIVO', NULL);
    PERFORM operar_simple(c[6], 'PYG', 'COBRO_A_CLIENTE', 1000000, u, 'Pago a cuenta', 'EFECTIVO', NULL);

    PERFORM operar_simple(c[7], 'ARS', 'DEPOSITO_CLIENTE', 1200000, u, 'Depósito de pesos', 'EFECTIVO', NULL);
    PERFORM operar_arbitraje(c[7], 'ARS', 'PYG', 600000, 6, 'MULTIPLICAR', u, 'Cambio de pesos a guaraníes', FALSE, FALSE, 'EFECTIVO', NULL);

    PERFORM operar_simple(c[8], 'USD', 'DEPOSITO_CLIENTE', 800, u, 'Depósito', 'EFECTIVO', NULL);
    op := operar_simple(c[8], 'USD', 'DEPOSITO_CLIENTE', 50, u, 'Depósito duplicado', 'EFECTIVO', NULL);
    PERFORM anular_operacion(op, u, 'Cargado dos veces por error');

    RETURN array_length(c, 1);
END $$;

-- 6. Permisos
REVOKE EXECUTE ON FUNCTION api_eliminar_cliente(INT), api_reiniciar_empresa(TEXT), api_cargar_demo() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION api_eliminar_cliente(INT), api_reiniciar_empresa(TEXT), api_cargar_demo() TO authenticated;
