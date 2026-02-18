-- Copyright (C) 2025 Patrik Dobias <xdobia13@vut.cz>
-- Released for the non-commercial use only. For licensing, please contact <malina@vut.cz>

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.types_pkg.all;
use work.reduce_pkg.all;

-- decompose based on second alternative in https://tches.iacr.org/index.php/TCHES/article/view/11160/10599
entity sec_decompose is
port (
    clk: in std_logic;
    rst: in std_logic;

    random_q: in std_logic_vector(5 downto 0);

    -- interface for mask conversions to enable efficient sharing
    conversion_s_axis_tdata: out slv_array_t(1 downto 0)(95 downto 0);
    conversion_s_axis_tuser: out std_logic_vector(3 downto 0);
    conversion_s_axis_tvalid: out std_logic;
    conversion_s_axis_tready: in std_logic;

    conversion_m_axis_tdata: in slv_array_t(1 downto 0)(95 downto 0);
    conversion_m_axis_tvalid: in std_logic;
    conversion_m_axis_tready: out std_logic;

    s_axis_tdata: in slv_array_t(1 downto 0)(95 downto 0);
    -- 0 -> δ = 44
    -- 1 -> δ = 16
    s_axis_tuser: in std_logic;
    s_axis_tvalid: in std_logic;
    s_axis_tready: out std_logic;

    -- high bits (only 6 bits are needed per coefficient)
    m_axis_tdata: out std_logic_vector(23 downto 0);
    -- low bits
    m_axis_low_bits_tdata: out slv_array_t(1 downto 0)(95 downto 0);
    m_axis_tvalid: out std_logic;
    m_axis_tready: in std_logic
);
end;

architecture behav of sec_decompose is
    signal coeffs: slv_array_t(1 downto 0)(95 downto 0);
    signal coeffs_mode: std_logic;
    signal coeffs_vld: std_logic;

    signal t: slv_array_t(1 downto 0)(95 downto 0);
    signal t_mode: std_logic;
    signal t_vld, t_vld_whole: std_logic;

    signal t_counter: natural range 0 to 3;
    signal t_counter_last: std_logic;

    signal coeffs_fifo_dout: slv_array_t(1 downto 0)(95 downto 0);
    signal mode_fifo_dout: std_logic_vector(0 downto 0);

    signal high_bits_fifo_din: slv_array_t(1 downto 0)(5 downto 0);
    signal high_bits_fifo_din_vld: std_logic;

    signal high_bits_fifo_dout: slv_array_t(1 downto 0)(5 downto 0);

    -- sec_mux signals
    signal sec_mux0_u: slv_array_t(1 downto 0)(5 downto 0);
    signal sec_mux0_c: std_logic;
    signal sec_mux0_random: std_logic_vector(5 downto 0);
    signal sec_mux0_mode: std_logic;
    signal sec_mux0_vld: std_logic;

    signal sec_mux0_counter: natural range 0 to 3;
    signal sec_mux0_counter_last: std_logic;

    signal sec_mux1_u: slv_array_t(1 downto 0)(5 downto 0);
    signal sec_mux1_random: std_logic_vector(5 downto 0);
    signal sec_mux1_mode: std_logic;
    signal sec_mux1_vld: std_logic;

    -- registering before unmasking
    signal high_bits_unmask_r: slv_array_t(1 downto 0)(5 downto 0);
    signal high_bits_unmask_mode_r: std_logic;
    signal high_bits_unmask_vld_r: std_logic;

    -- unmasking high bits signals
    signal high_bits_unmasked: std_logic_vector(23 downto 0);
    signal high_bits_unmasked_mode: std_logic;
    signal high_bits_unmasked_vld: std_logic;

    signal high_bits_unmasked_counter: natural range 0 to 3;
    signal high_bits_unmasked_counter_last: std_logic;

    -- assigning DON'T TOUCH attribute
    attribute dont_touch: string;
    attribute dont_touch of behav: architecture is "yes";
    attribute dont_touch of sec_mux0_u, sec_mux0_c, sec_mux1_u, high_bits_unmask_r, high_bits_unmasked: signal is "yes";
begin
    s_axis_tready <= (not coeffs_vld) or ((not t_vld_whole) and t_counter_last);

    conversion_s_axis_tdata <= t;
    conversion_s_axis_tuser <= "1001";
    conversion_s_axis_tvalid <= t_vld_whole;

    conversion_m_axis_tready <= ((not sec_mux0_vld) or (not sec_mux1_vld) or (not high_bits_unmask_vld_r) or (not high_bits_unmasked_vld) or (not m_axis_tvalid) or m_axis_tready) and sec_mux0_counter_last;

    coeffs_fifo_g: for i in 0 to 1 generate
        coeffs_fifo: entity work.small_fifo
        generic map (
            DATA_WIDTH => 96,
            DATA_DEPTH => 64
        )
        port map (
            clk => clk,
            rst => rst,

            din => s_axis_tdata(i),
            din_vld => s_axis_tvalid and s_axis_tready,

            dout => coeffs_fifo_dout(i),
            dout_vld => open, -- it stores input coefficients for computation before outputing, so it must have always data when needed
            dout_rdy => high_bits_unmasked_vld and ((not m_axis_tvalid) or m_axis_tready)
        );
    end generate;

    high_bits_fifo_shares_g: for i in 0 to 1 generate
        high_bits_fifo: entity work.small_fifo
        generic map (
            DATA_WIDTH => 6,
            DATA_DEPTH => 256
        )
        port map (
            clk => clk,
            rst => rst,

            din => high_bits_fifo_din(i),
            din_vld => high_bits_fifo_din_vld,

            dout => high_bits_fifo_dout(i),
            dout_vld => open, -- it stores t mod 44
            dout_rdy => sec_mux1_vld and ((not high_bits_unmask_vld_r) or (not high_bits_unmasked_vld) or (not m_axis_tvalid) or m_axis_tready)
        );
    end generate;

    mode_fifo: entity work.small_fifo
    generic map (
        DATA_WIDTH => 1,
        DATA_DEPTH => 64
    )
    port map (
        clk => clk,
        rst => rst,

        din => (others => s_axis_tuser),
        din_vld => s_axis_tvalid and s_axis_tready,

        dout => mode_fifo_dout,
        dout_vld => open, -- will be always valid when needed,
        dout_rdy => conversion_m_axis_tvalid and conversion_m_axis_tready
    );

    coeffs_p: process(clk) is
    begin
        if rising_edge(clk) then
            if ((not coeffs_vld) or ((not t_vld_whole) and t_counter_last)) = '1' then
                coeffs <= s_axis_tdata;
                coeffs_mode <= s_axis_tuser;
            end if;

            if rst = '1' then
                coeffs_vld <= '0';
            else
                if s_axis_tvalid = '1' then
                    coeffs_vld <= '1';
                elsif ((not t_vld_whole) and t_counter_last) = '1' then
                    coeffs_vld <= '0';
                end if;
            end if;
        end if;
    end process;

    t_counter_last <= '1' when t_counter = 3 else '0';

    -- compute t = (-δ * x + (Q - 1) / 2) % Q
    t_p: process(clk) is
        variable x: unsigned(29 downto 0);
        -- how many times we need to subtract Q, so it is in range (-Q; Q)
        variable w: unsigned(5 downto 0);
    begin
        if rising_edge(clk) then
            if ((not t_vld_whole) or conversion_s_axis_tready) = '1' then
                for i in 0 to 1 loop
                    x := "000000" & unsigned(coeffs(i)(23 + 24 * t_counter downto 24 * t_counter));

                    if coeffs_mode = '0' then
                        -- x * 44
                        x := (x(24 downto 0) & "00000") + (x(25 downto 0) & "000") + (x(26 downto 0) & "00");
                    else
                        -- x * 16
                        x := x(25 downto 0) & "0000";
                    end if;

                    w := x(28 downto 23);

                    -- add only (Q - 1) / 4 as it is added to both shares and add `w` times Q so it is in range (-Q; Q)
                    x := ("00" & x"01ff800") + (w & (22 downto 0 => '0')) - ('0' & w & (12 downto 0 => '0')) + w - x;

                    -- make sure the result is in range <0; Q)
                    if x(29) = '1' then
                        t(i)(23 + 24 * t_counter downto 24 * t_counter) <= std_logic_vector(x(23 downto 0) + x"7fe001");
                    else
                        t(i)(23 + 24 * t_counter downto 24 * t_counter) <= std_logic_vector(x(23 downto 0));
                    end if;
                end loop;

                t_mode <= coeffs_mode;
            end if;

            if rst = '1' then
                t_vld <= '0';
                t_vld_whole <= '0';
                t_counter <= 0;
            else
                t_vld <= coeffs_vld and ((not t_vld_whole) or conversion_s_axis_tready);

                if coeffs_vld = '1' and t_counter = 3 then
                    t_vld_whole <= '1';
                elsif conversion_s_axis_tready = '1' then
                    t_vld_whole <= '0';
                end if;

                if (coeffs_vld and ((not t_vld_whole) or conversion_s_axis_tready)) = '1' then
                    if t_counter_last = '1' then
                        t_counter <= 0;
                    else
                        t_counter <= t_counter + 1;
                    end if;
                end if;
            end if;
        end if;
    end process;

    -- compute t % δ for δ = 16 it is simply discarding MSB, for δ = 44 it is found gradually
    mod_p: process(clk) is
        -- just for simpler indexing
        variable t_v: unsigned(23 downto 0);
        -- temporary computations during mod 44
        variable a, b, c, d, e, f, g, h: unsigned(6 downto 0);
        variable x: unsigned(6 downto 0);
    begin
        if rising_edge(clk) then
            for i in 0 to 1 loop
                t_v := unsigned(t(i)(23 + 24 * ((t_counter - 1) mod 4) downto 24 * ((t_counter - 1) mod 4)));

                if t_mode = '1' then
                    x := "000" & t_v(3 downto 0);
                else
                    x := "00" & t_v(4 downto 0);

                    -- the computation follows combining bits multiplied by their 2 power mod 44,
                    -- e.g. first one is t_6 * (2^6 % 44) + t_11 * (2^11 % 44)

                    -- 0, 20, 24
                    a := "00" & (t_v(6) xor t_v(11)) & ((not t_v(6)) and t_v(11)) & (t_v(6) and (not t_v(11))) & "00";
                    b := "00" & (t_v(16) xor t_v(21)) & ((not t_v(16)) and t_v(21)) & (t_v(16) and (not t_v(21))) & "00";

                    -- 0, 4, 32, 36, 40
                    c := '0' & ((t_v(7) and (not t_v(12))) or t_v(8)) & '0' & ((t_v(7) and (not t_v(8)) and (not t_v(12))) or ((not t_v(7)) and t_v(8) and t_v(12))) & (((not t_v(7) and (t_v(8) xor t_v(12)))) or (t_v(7) and t_v(8) and t_v(12))) & "00";
                    d := '0' & ((t_v(17) and (not t_v(22))) or t_v(18)) & '0' & ((t_v(17) and (not t_v(18)) and (not t_v(22))) or ((not t_v(17)) and t_v(18) and t_v(22))) & (((not t_v(17) and (t_v(18) xor t_v(22)))) or (t_v(17) and t_v(18) and t_v(22))) & "00";

                    -- 0, 12, 28, 40
                    e := '0' & (t_v(9) and t_v(10)) & (t_v(9) and (not t_v(10))) & (t_v(9) or t_v(10)) & (t_v(9) xor t_v(10)) & "00";
                    f := '0' & (t_v(19) and t_v(20)) & (t_v(19) and (not t_v(20))) & (t_v(19) or t_v(20)) & (t_v(19) xor t_v(20)) & "00";

                    -- 0, 4, 8, 16, 32, 40
                    g := '0' & (t_v(5) and (not (t_v(13) and t_v(23)))) & ((not t_v(5)) and t_v(13) and t_v(23)) & (t_v(13) xor t_v(23)) & (t_v(5) and t_v(13) and t_v(23)) & "00";
                    -- 0, 4, 16, 32
                    h := '0' & ((not t_v(14)) and t_v(15)) & (t_v(14) and (not t_v(15))) & '0' & (t_v(14) and t_v(15)) & "00";

                    a := a + b;
                    c := c + d;
                    e := e + f;
                    g := g + h;

                    if a >= 44 then
                        a := a - 44;
                    end if;

                    if c >= 44 then
                        c := c - 44;
                    end if;

                    if e >= 44 then
                        e := e - 44;
                    end if;

                    if g >= 44 then
                        g := g - 44;
                    end if;

                    a := a + c;
                    e := e + g;

                    if a >= 44 then
                        a := a - 44;
                    end if;

                    if e >= 44 then
                        e := e - 44;
                    end if;

                    a := a + e;

                    if a >= 44 then
                        a := a - 44;
                    end if;

                    x := x + a;

                    if x >= 44 then
                        x := x - 44;
                    end if;
                end if;

                high_bits_fifo_din(i) <= std_logic_vector(x(5 downto 0));
            end loop;

            if rst = '1' then
                high_bits_fifo_din_vld <= '0';
            else
                high_bits_fifo_din_vld <= t_vld;
            end if;
        end if;
    end process;

    sec_mux0_counter_last <= '1' when sec_mux0_counter = 3 else '0';

    -- converting carry to arithmetic masking (part 1)
    sec_mux0_p: process(clk) is
        variable x: unsigned(5 downto 0);
    begin
        if rising_edge(clk) then
            if ((not sec_mux0_vld) or (not sec_mux1_vld) or (not high_bits_unmask_vld_r) or (not high_bits_unmasked_vld) or (not m_axis_tvalid) or m_axis_tready) = '1' then
                x := unsigned(random_q) + 1;

                if mode_fifo_dout(0) = '0' then
                    if x = 44 then
                        x := "000000";
                    end if;
                else
                    x := "00" & x(3 downto 0);
                end if;

                if conversion_m_axis_tdata(1)(23 + 24 * sec_mux0_counter) = '0' then
                    sec_mux0_u(0) <= random_q;
                    sec_mux0_u(1) <= std_logic_vector(x);
                else
                    sec_mux0_u(0) <= std_logic_vector(x);
                    sec_mux0_u(1) <= random_q;
                end if;

                sec_mux0_c <= conversion_m_axis_tdata(0)(23 + 24 * sec_mux0_counter);

                sec_mux0_random <= random_q;

                sec_mux0_mode <= mode_fifo_dout(0);
            end if;

            if rst = '1' then
                sec_mux0_vld <= '0';
                sec_mux0_counter <= 0;
            else
                if conversion_m_axis_tvalid = '1' then
                    sec_mux0_vld <= '1';
                elsif ((not sec_mux1_vld) or (not high_bits_unmask_vld_r) or (not high_bits_unmasked_vld) or (not m_axis_tvalid) or m_axis_tready) = '1' then
                    sec_mux0_vld <= '0';
                end if;

                if (conversion_m_axis_tvalid and ((not sec_mux0_vld) or (not sec_mux1_vld) or (not high_bits_unmask_vld_r) or (not high_bits_unmasked_vld) or (not m_axis_tvalid) or m_axis_tready)) = '1' then
                    if sec_mux0_counter_last = '1' then
                        sec_mux0_counter <= 0;
                    else
                        sec_mux0_counter <= sec_mux0_counter + 1;
                    end if;
                end if;
            end if;
        end if;
    end process;

    -- converting carry to arithmetic masking (part 2)
    sec_mux1_p: process(clk) is
    begin
        if rising_edge(clk) then
            if ((not sec_mux1_vld) or (not high_bits_unmask_vld_r) or (not high_bits_unmasked_vld) or (not m_axis_tvalid) or m_axis_tready) = '1' then
                sec_mux1_u(0) <= (5 downto 0 => sec_mux0_c) and sec_mux0_u(0);
                sec_mux1_u(1) <= (5 downto 0 => not sec_mux0_c) and sec_mux0_u(1);

                sec_mux1_random <= sec_mux0_random;

                sec_mux1_mode <= sec_mux0_mode;
            end if;

            if rst = '1' then
                sec_mux1_vld <= '0';
            else
                if sec_mux0_vld = '1' then
                    sec_mux1_vld <= '1';
                elsif ((not high_bits_unmask_vld_r) or (not high_bits_unmasked_vld) or (not m_axis_tvalid) or m_axis_tready) = '1' then
                    sec_mux1_vld <= '0';
                end if;
            end if;
        end if;
    end process;

    -- register before unmasking
    high_bits_unmask_p: process(clk) is
        variable x: unsigned(6 downto 0);
    begin
        if rising_edge(clk) then
            if (sec_mux1_vld and ((not high_bits_unmask_vld_r) or (not high_bits_unmasked_vld) or (not m_axis_tvalid) or m_axis_tready)) = '1' then
                x := '0' & unsigned(high_bits_fifo_dout(0)) - unsigned(sec_mux1_u(0) or sec_mux1_u(1));

                if sec_mux1_mode = '0' then
                    if x(6) = '1' then
                        x := x + 44;
                    end if;
                else
                    x := "000" & x(3 downto 0);
                end if;

                high_bits_unmask_r(0) <= std_logic_vector(x(5 downto 0));

                x := '0' & unsigned(high_bits_fifo_dout(1)) + unsigned(sec_mux1_random);

                if sec_mux1_mode = '0' then
                    if x >= 44 then
                        x := x - 44;
                    end if;
                else
                    x := "000" & x(3 downto 0);
                end if;

                high_bits_unmask_r(1) <= std_logic_vector(x(5 downto 0));

                high_bits_unmask_mode_r <= sec_mux1_mode;
            end if;

            if rst = '1' then
                high_bits_unmask_vld_r <= '0';
            else
                if sec_mux1_vld = '1' then
                    high_bits_unmask_vld_r <= '1';
                elsif ((not high_bits_unmasked_vld) or (not m_axis_tvalid) or m_axis_tready) = '1' then
                    high_bits_unmask_vld_r <= '0';
                end if;
            end if;
        end if;
    end process;

    high_bits_unmasked_counter_last <= '1' when high_bits_unmasked_counter = 3 else '0';

    high_bits_unmasked_p: process(clk) is
        variable x: unsigned(6 downto 0);
    begin
        if rising_edge(clk) then
            if ((not high_bits_unmasked_vld) or (not m_axis_tvalid) or m_axis_tready) = '1' then
                x := '0' & unsigned(high_bits_unmask_r(0)) + unsigned(high_bits_unmask_r(1));

                if high_bits_unmask_mode_r = '0' then
                    if x >= 44 then
                        x := x - 44;
                    end if;
                else
                    x := "000" & x(3 downto 0);
                end if;

                high_bits_unmasked(5 + 6 * high_bits_unmasked_counter downto 6 * high_bits_unmasked_counter) <= std_logic_vector(x(5 downto 0));

                high_bits_unmasked_mode <= high_bits_unmask_mode_r;
            end if;

            if rst = '1' then
                high_bits_unmasked_vld <= '0';
                high_bits_unmasked_counter <= 0;
            else
                if (high_bits_unmask_vld_r and high_bits_unmasked_counter_last) = '1' then
                    high_bits_unmasked_vld <= '1';
                elsif ((not m_axis_tvalid) or m_axis_tready) = '1' then
                    high_bits_unmasked_vld <= '0';
                end if;

                if (high_bits_unmask_vld_r and ((not high_bits_unmasked_vld) or (not m_axis_tvalid) or m_axis_tready)) = '1' then
                    if high_bits_unmasked_counter_last = '1' then
                        high_bits_unmasked_counter <= 0;
                    else
                        high_bits_unmasked_counter <= high_bits_unmasked_counter + 1;
                    end if;
                end if;
            end if;
        end if;
    end process;

    -- compute low bits by subtracting `high` * (q - 1) / δ
    out_p: process(clk) is
        variable high_v: unsigned(5 downto 0);
        variable low: std_logic_vector(23 downto 0);
    begin
        if rising_edge(clk) then
            if ((not m_axis_tvalid) or m_axis_tready) = '1' then
                for i in 0 to 3 loop
                    high_v := unsigned(high_bits_unmasked(5 + 6 * i downto 6 * i));

                    m_axis_tdata(5 + 6 * i downto 6 * i) <= std_logic_vector(high_v);

                    -- `high` * (q - 1) / δ
                    if high_bits_unmasked_mode = '1' then
                        low := std_logic_vector(('0' & high_v(3 downto 0) & (18 downto 0 => '0')) - (high_v(3 downto 0) & (8 downto 0 => '0')));
                    else
                        low := std_logic_vector(('0' & high_v & (16 downto 0 => '0')) + (high_v & (15 downto 0 => '0')) - (high_v & (12 downto 0 => '0')) + (high_v & (10 downto 0 => '0')));
                    end if;

                    m_axis_low_bits_tdata(0)(23 + 24 * i downto 24 * i) <= dilithium_sub_reduce(coeffs_fifo_dout(0)(23 + 24 * i downto 24 * i), low);
                    m_axis_low_bits_tdata(1)(23 + 24 * i downto 24 * i) <= coeffs_fifo_dout(1)(23 + 24 * i downto 24 * i);
                end loop;
            end if;

            if rst = '1' then
                m_axis_tvalid <= '0';
            else
                if high_bits_unmasked_vld = '1' then
                    m_axis_tvalid <= '1';
                elsif m_axis_tready = '1' then
                    m_axis_tvalid <= '0';
                end if;
            end if;
        end if;
    end process;
end;
