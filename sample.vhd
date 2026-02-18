-- Copyright (C) 2024 Patrik Dobias <xdobia13@vut.cz>
-- Released for the non-commercial use only. For licensing, please contact <malina@vut.cz>

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.params_pkg.all;
use work.reduce_pkg.all;
use work.sample_pkg.all;
use work.types_pkg.all;

-- samples coefficients from bytes
-- different sampling methods require different number of clock cycles
entity sample is
port (
    clk: in std_logic;
    rst: in std_logic;

    random: in std_logic_vector(24 downto 0);

    -- 0 - sample bounded ETA=2 - input shake-256
    -- 1 - sample bounded ETA=4 - input shake-256
    -- must be valid during whole computation
    mode: in std_logic;

    -- interface for mask conversions to enable efficient sharing
    sec_conversion_s_axis_tdata: out slv_array_t(1 downto 0)(95 downto 0);
    sec_conversion_s_axis_tuser: out std_logic_vector(3 downto 0);
    sec_conversion_s_axis_tvalid: out std_logic;
    sec_conversion_s_axis_tready: in std_logic;

    sec_conversion_m_axis_tdata: in slv_array_t(1 downto 0)(95 downto 0);
    sec_conversion_m_axis_tuser: in std_logic_vector(3 downto 0);
    sec_conversion_m_axis_tvalid: in std_logic;
    sec_conversion_m_axis_tready: out std_logic;

    -- data from keccak that should be used during sampling
    -- for NTT unmasked - only 0 has valid data
    -- for cbd and bounded masked - both shares has valid data
    s_axis_tdata: in slv_array_t(1 downto 0)(63 downto 0);
    -- indicates, which sampling should be used
    -- 000 - sample NTT (kyber) - input shake-128
    -- 001 - sample cbd ETA=2 (kyber) - input shake-256
    -- 010 - sample cbd ETA=3 (kyber) - input shake-256
    -- 100 - sample NTT (dilithium) - input shake-128
    -- 101 - sample bounded ETA=2 (dilithium) - input shake-256
    -- 110 - sample bounded ETA=4 (dilithium) - input shake-256
    s_axis_tuser: in std_logic_vector(2 downto 0);
    s_axis_tvalid: in std_logic;
    s_axis_tready: out std_logic;

    -- sampled coefficients 8 (4) at a time for kyber (dilithium)
    -- for NTT unmasked - only 0 has valid data
    -- for cbd and bounded masked - both shares has valid data
    m_axis_tdata: out slv_array_t(1 downto 0)(95 downto 0);
    m_axis_tuser: out std_logic_vector(2 downto 0);
    -- indicates that all 256 coefficients were sampled
    m_axis_tlast: out std_logic;
    m_axis_tvalid: out std_logic;
    m_axis_tready: in std_logic
);
end;

architecture behav of sample is
    type x3b_shift_reg_t is array(natural range <>) of std_logic_vector(2 downto 0);

    signal s_axis_tdata_ser: std_logic_vector(127 downto 0);
    signal reg_ready_m_axis_tdata_ser: std_logic_vector(127 downto 0);

    signal reg_ready_m_axis_tdata: slv_array_t(1 downto 0)(63 downto 0);
    signal reg_ready_m_axis_tuser: std_logic_vector(2 downto 0);
    signal reg_ready_m_axis_tvalid, reg_ready_m_axis_tready: std_logic;

    -- bytes selection from incoming data
    signal bytes: slv_array_t(1 downto 0)(79 downto 0);
    signal bytes_mux: std_logic_vector(2 downto 0);
    signal bytes_vld, bytes_next: std_logic;

    -- reject NTT signals
    signal rej_ntt_coeffs, rej_ntt_coeffs_reordered: std_logic_vector(47 downto 0);
    signal rej_ntt_coeffs_vld: std_logic_vector(3 downto 0);
    signal rej_ntt_coeffs_reordered_count_vld: natural range 0 to 4;

    -- as we want to output 8 (4) coeffs at a time, we need to store them in registers until 8 (4) coeffs are valid for kyber (dilithium)
    signal rej_ntt_valid_coeffs: std_logic_vector(131 downto 0);
    signal rej_ntt_valid_coeffs_count_vld: natural range 0 to 11;
    signal rej_ntt_valid_coeffs_vld: std_logic;

    -- sec_sample_cbd signals
    signal sec_sample_cbd_s_axis_tdata: slv_array_t(1 downto 0)(47 downto 0);
    signal sec_sample_cbd_s_axis_tvalid, sec_sample_cbd_s_axis_tready: std_logic;

    signal sec_sample_cbd_coeffs: slv_array_t(1 downto 0)(23 downto 0);
    signal sec_sample_cbd_coeffs_vld: std_logic;

    signal sample_cbd_count: natural range 0 to 31;
    signal sample_cbd_loaded_all: std_logic;

    -- sec_sample_bounded signals
    signal sec_sample_bounded_s_axis_tdata: slv_array_t(1 downto 0)(15 downto 0);
    signal sec_sample_bounded_s_axis_tvalid, sec_sample_bounded_s_axis_tready: std_logic;

    signal sec_sample_bounded_coeffs: slv_array_t(1 downto 0)(15 downto 0);
    signal sec_sample_bounded_coeffs_vld: std_logic;

    -- `sampled_fifo` signals
    signal sampled_fifo_din: slv_array_t(1 downto 0)(23 downto 0);
    signal sampled_fifo_din_vld: std_logic;

    signal sampled_fifo_dout: slv_array_t(1 downto 0)(23 downto 0);
    signal sampled_fifo_dout_vld: std_logic_vector(1 downto 0);
    signal sampled_fifo_dout_rdy: std_logic;

    signal sampled_fifo_afull: std_logic_vector(1 downto 0);

    -- indicates rejection can read new bytes
    signal rej_next: std_logic;

    -- rejected coefficients
    signal coeffs_r: slv_array_t(1 downto 0)(95 downto 0);
    signal coeffs_vld, coeffs_vld_r, coeffs_next: std_logic;

    signal coeffs_count: natural range 0 to 63;
    signal coeffs_count_last, coeffs_count_last_r: std_logic;

    signal mode_shift_reg: x3b_shift_reg_t(2 downto 0);

    component sec_sample_bounded is
    port (
        clk: in std_logic;
        rst: in std_logic;

        random: in std_logic_vector(24 downto 0);

        mode: in std_logic;

        s_axis_tdata: in slv_array_t(1 downto 0)(15 downto 0);
        s_axis_tvalid: in std_logic;
        s_axis_tready: out std_logic;

        coeffs: out slv_array_t(1 downto 0)(15 downto 0);
        coeffs_vld: out std_logic
    );
    end component;

    component sec_sample_cbd is
    port (
        clk: in std_logic;
        rst: in std_logic;

        random: in std_logic_vector(17 downto 0);

        mode: in std_logic;

        s_axis_tdata: in slv_array_t(1 downto 0)(47 downto 0);
        s_axis_tvalid: in std_logic;
        s_axis_tready: out std_logic;

        coeffs: out slv_array_t(1 downto 0)(23 downto 0);
        coeffs_vld: out std_logic
    );
    end component;

    -- assigning DON'T TOUCH attribute
    attribute dont_touch: string;
    attribute dont_touch of sec_sample_bounded, sec_sample_cbd: component is "yes";
begin
    m_axis_tdata <= coeffs_r;
    m_axis_tuser <= mode_shift_reg(0);
    m_axis_tlast <= coeffs_count_last_r;
    m_axis_tvalid <= coeffs_vld_r;

    reg_ready: entity work.reg_ready
    generic map (
        DATA_WIDTH => 128,
        USER_WIDTH => 3
    )
    port map (
        clk => clk,
        rst => rst,

        s_axis_tdata => s_axis_tdata_ser,
        s_axis_tuser => s_axis_tuser,
        s_axis_tvalid => s_axis_tvalid,
        s_axis_tready => s_axis_tready,

        m_axis_tdata => reg_ready_m_axis_tdata_ser,
        m_axis_tuser => reg_ready_m_axis_tuser,
        m_axis_tvalid => reg_ready_m_axis_tvalid,
        m_axis_tready => reg_ready_m_axis_tready
    );

    s_axis_tdata_ser <= slv_array_ser(s_axis_tdata, 2, 64);

    reg_ready_m_axis_tdata <= slv_array_deser(reg_ready_m_axis_tdata_ser, 2, 64);

    reg_ready_m_axis_tready <= '1' when (coeffs_vld_r and coeffs_count_last_r and m_axis_tready) = '1' else bytes_next;

    with bytes_mux select bytes_next <=
        (not bytes_vld or rej_next) when "100" | "001" | "011" | "111",
        (not bytes_vld or rej_next) and ((not reg_ready_m_axis_tuser(1) and not reg_ready_m_axis_tuser(0)) or (not reg_ready_m_axis_tuser(2) and reg_ready_m_axis_tuser(1))) when "000",
        '0' when others;

    -- select bytes at given offset from incoming data
    proc_bytes: process(clk) is
    begin
        if rising_edge(clk) then
            if (reg_ready_m_axis_tvalid and (not bytes_vld or rej_next)) = '1' then
                for i in 0 to 1 loop
                    case bytes_mux is
                        when "000" => bytes(i)(63 downto 0) <= reg_ready_m_axis_tdata(i)(63 downto 0);
                        when "001" => bytes(i)(79 downto 0) <= reg_ready_m_axis_tdata(i)(63 downto 0) & bytes(i)(63 downto 48);
                        when "010" => bytes(i)(47 downto 0) <= reg_ready_m_axis_tdata(i)(15 downto 0) & bytes(i)(79 downto 48);
                        when "011" => bytes(i)(47 downto 0) <= reg_ready_m_axis_tdata(i)(63 downto 16);
                        when "100" => bytes(i)(31 downto 0) <= reg_ready_m_axis_tdata(i)(63 downto 32);
                        when "101" => bytes(i)(15 downto 0) <= reg_ready_m_axis_tdata(i)(31 downto 16);
                        when "110" => bytes(i)(15 downto 0) <= reg_ready_m_axis_tdata(i)(47 downto 32);
                        when others => bytes(i)(15 downto 0) <= reg_ready_m_axis_tdata(i)(63 downto 48);
                    end case;
                end loop;
            end if;

            if (rst or coeffs_count_last_r or (coeffs_count_last and coeffs_vld)) = '1' then
                bytes_vld <= '0';
                bytes_mux <= "000";
            else
                if reg_ready_m_axis_tvalid = '1' then
                    bytes_vld <= '1';
                elsif rej_next = '1' then
                    bytes_vld <= '0';
                end if;

                if (reg_ready_m_axis_tvalid and (not bytes_vld or rej_next)) = '1' then
                    case bytes_mux is
                        when "000" =>
                            case reg_ready_m_axis_tuser is
                                when "001" => bytes_mux <= "100";
                                when "101" | "110" => bytes_mux <= "101";
                                when others => bytes_mux <= "001";
                            end case;
                        -- shift by 6B
                        when "001" => bytes_mux <= "010";
                        -- shift by 6B
                        when "010" => bytes_mux <= "011";
                        -- shift by 2B
                        when "101" => bytes_mux <= "110";
                        -- shift by 2B
                        when "110" => bytes_mux <= "111";
                        when others => bytes_mux <= "000";
                    end case;
                end if;
            end if;
        end if;
    end process;

    -- reordering of NTT rejection based on selected mode
    rej_ntt_coeffs <= (bytes(0)(47) and (not mode_shift_reg(mode_shift_reg'left)(2))) & bytes(0)(46 downto 24) &
        (bytes(0)(23) and (not mode_shift_reg(mode_shift_reg'left)(2))) & bytes(0)(22 downto 0);
    rej_ntt_coeffs_vld <= rej_ntt(bytes(0)(47 downto 0), mode_shift_reg(mode_shift_reg'left)(2));

    reorder_rej_ntt(rej_ntt_coeffs, rej_ntt_coeffs_vld, rej_ntt_coeffs_reordered, rej_ntt_coeffs_reordered_count_vld);

    rej_ntt_valid_coeffs_vld <= '1' when rej_ntt_valid_coeffs_count_vld > 7 else '0';

    proc_rej_ntt: process(clk) is
    begin
        if rising_edge(clk) then
            if mode_shift_reg(mode_shift_reg'left)(1 downto 0) = "00" then
                if rej_ntt_valid_coeffs_count_vld = 11 then if coeffs_next = '1' then rej_ntt_valid_coeffs(83 downto 0) <= rej_ntt_coeffs_reordered & rej_ntt_valid_coeffs(131 downto 96); end if;
                elsif rej_ntt_valid_coeffs_count_vld = 10 then if coeffs_next = '1' then rej_ntt_valid_coeffs(71 downto 0) <= rej_ntt_coeffs_reordered & rej_ntt_valid_coeffs(119 downto 96); end if;
                elsif rej_ntt_valid_coeffs_count_vld = 9 then if coeffs_next = '1' then rej_ntt_valid_coeffs(59 downto 0) <= rej_ntt_coeffs_reordered & rej_ntt_valid_coeffs(107 downto 96); end if;
                elsif rej_ntt_valid_coeffs_count_vld = 8 then if coeffs_next = '1' then rej_ntt_valid_coeffs(47 downto 0) <= rej_ntt_coeffs_reordered; end if;
                elsif rej_ntt_valid_coeffs_count_vld = 7 then rej_ntt_valid_coeffs(131 downto 0) <= rej_ntt_coeffs_reordered & rej_ntt_valid_coeffs(83 downto 0);
                elsif rej_ntt_valid_coeffs_count_vld = 6 then rej_ntt_valid_coeffs(119 downto 0) <= rej_ntt_coeffs_reordered & rej_ntt_valid_coeffs(71 downto 0);
                elsif rej_ntt_valid_coeffs_count_vld = 5 then rej_ntt_valid_coeffs(107 downto 0) <= rej_ntt_coeffs_reordered & rej_ntt_valid_coeffs(59 downto 0);
                elsif rej_ntt_valid_coeffs_count_vld = 4 then rej_ntt_valid_coeffs(95 downto 0) <= rej_ntt_coeffs_reordered & rej_ntt_valid_coeffs(47 downto 0);
                elsif rej_ntt_valid_coeffs_count_vld = 3 then rej_ntt_valid_coeffs(83 downto 0) <= rej_ntt_coeffs_reordered & rej_ntt_valid_coeffs(35 downto 0);
                elsif rej_ntt_valid_coeffs_count_vld = 2 then rej_ntt_valid_coeffs(71 downto 0) <= rej_ntt_coeffs_reordered & rej_ntt_valid_coeffs(23 downto 0);
                elsif rej_ntt_valid_coeffs_count_vld = 1 then rej_ntt_valid_coeffs(59 downto 0) <= rej_ntt_coeffs_reordered & rej_ntt_valid_coeffs(11 downto 0);
                else rej_ntt_valid_coeffs(47 downto 0) <= rej_ntt_coeffs_reordered;
                end if;
            end if;

            if (rst or (coeffs_count_last and coeffs_vld and coeffs_next)) = '1' then
                rej_ntt_valid_coeffs_count_vld <= 0;
            elsif mode_shift_reg(mode_shift_reg'left)(1 downto 0) = "00" then
                if rej_next = '1' then
                    if bytes_vld = '1' then
                        -- if 8 (4 for dilithium) coeffs are valid we will read them, so next cycle they will be invalidated
                        if rej_ntt_valid_coeffs_vld = '1' then
                            rej_ntt_valid_coeffs_count_vld <= rej_ntt_valid_coeffs_count_vld - 8 + rej_ntt_coeffs_reordered_count_vld;
                        else
                            rej_ntt_valid_coeffs_count_vld <= rej_ntt_valid_coeffs_count_vld + rej_ntt_coeffs_reordered_count_vld;
                        end if;
                    -- if 8 (4 for dilithium) coeffs are valid we will read them, so next cycle they will be invalidated
                    elsif rej_ntt_valid_coeffs_vld = '1' then
                        rej_ntt_valid_coeffs_count_vld <= rej_ntt_valid_coeffs_count_vld - 8;
                    end if;
                end if;
            end if;
        end if;
    end process;

    sec_sample_cbd_i: entity work.sec_sample_cbd
    port map (
        clk => clk,
        rst => rst or (coeffs_vld_r and coeffs_count_last_r),

        random => random(17 downto 0),

        s_axis_tdata => sec_sample_cbd_s_axis_tdata,
        s_axis_tvalid => sec_sample_cbd_s_axis_tvalid,
        s_axis_tready => sec_sample_cbd_s_axis_tready,

        coeffs => sec_sample_cbd_coeffs,
        coeffs_vld => sec_sample_cbd_coeffs_vld
    );

    sec_sample_cbd_shares_g: for i in 0 to 1 generate
        sec_sample_cbd_g: for j in 0 to 15 generate
            sec_sample_cbd_s_axis_tdata(i)(2 + 3 * j downto 3 * j) <= '0' & bytes(i)(1 + 2 * j downto 2 * j) when mode_shift_reg(mode_shift_reg'left)(0) = '1' else bytes(i)(2 + 3 * j downto 3 * j);
        end generate;
    end generate;

    sec_sample_cbd_s_axis_tvalid <= bytes_vld and (not sampled_fifo_afull(0)) and (not sample_cbd_loaded_all) when mode_shift_reg(mode_shift_reg'left)(2) = '0' and mode_shift_reg(mode_shift_reg'left)(1 downto 0) /= "00" else '0';

    sample_cbd_count_p: process(clk) is
    begin
        if rising_edge(clk) then
            if (rst or (coeffs_vld_r and coeffs_count_last_r)) = '1' then
                sample_cbd_count <= 0;
                sample_cbd_loaded_all <= '0';
            else
                if (sec_sample_cbd_s_axis_tvalid and sec_sample_cbd_s_axis_tready) = '1' then
                    if sample_cbd_count = 31 then
                        sample_cbd_count <= 0;
                        sample_cbd_loaded_all <= '1';
                    else
                        sample_cbd_count <= sample_cbd_count + 1;
                    end if;
                end if;
            end if;
        end if;
    end process;

    sec_sample_bounded_i: entity work.sec_sample_bounded
    port map (
        clk => clk,
        rst => rst or (coeffs_vld_r and coeffs_count_last_r),

        random => random(24 downto 0),

        mode => mode,

        s_axis_tdata => sec_sample_bounded_s_axis_tdata,
        s_axis_tvalid => sec_sample_bounded_s_axis_tvalid,
        s_axis_tready => sec_sample_bounded_s_axis_tready,

        coeffs => sec_sample_bounded_coeffs,
        coeffs_vld => sec_sample_bounded_coeffs_vld
    );

    sec_sample_bounded_s_axis_tdata <= (0 => bytes(0)(15 downto 0), 1 => bytes(1)(15 downto 0));
    sec_sample_bounded_s_axis_tvalid <= bytes_vld and (not sampled_fifo_afull(0)) when mode_shift_reg(mode_shift_reg'left)(2) = '1' and mode_shift_reg(mode_shift_reg'left)(1 downto 0) /= "00" else '0';

    -- `sec_conversion` assignments
    sec_conversion_p: process(all) is
    begin
        for i in 0 to 1 loop
            sec_conversion_s_axis_tdata(i) <= (others => '0');

            if mode_shift_reg(mode_shift_reg'left)(2) = '0' then
                for j in 0 to 7 loop
                    sec_conversion_s_axis_tdata(i)(2 + 12 * j downto 12 * j) <= sampled_fifo_dout(i)(2 + 3 * j downto 3 * j);
                end loop;
            else
                for j in 0 to 3 loop
                    sec_conversion_s_axis_tdata(i)(3 + 24 * j downto 24 * j) <= sampled_fifo_dout(i)(3 + 4 * j downto 4 * j);
                end loop;
            end if;
        end loop;
    end process;

    sec_conversion_s_axis_tuser <= "0100" when mode_shift_reg(mode_shift_reg'left)(2) = '0' else "1100";
    sec_conversion_s_axis_tvalid <= sampled_fifo_dout_vld(0);

    sec_conversion_m_axis_tready <= coeffs_next;

    -- holds coefficients before b2a conversion to compensate for when conversion component is not able to accept more data
    sampled_fifo_g: for i in 0 to 1 generate
        sampled_fifo: entity work.small_fifo
        generic map (
            DATA_WIDTH => 24,
            DATA_DEPTH => 64,
            ALMOST_FULL_OFFSET => 32
        ) port map (
            clk => clk,
            rst => rst or (coeffs_vld_r and coeffs_count_last_r),

            din => sampled_fifo_din(i),
            din_vld => sampled_fifo_din_vld,

            dout => sampled_fifo_dout(i),
            dout_vld => sampled_fifo_dout_vld(i),
            dout_rdy => sampled_fifo_dout_rdy,

            afull => sampled_fifo_afull(i)
        );
    end generate;

    sampled_fifo_din <= sec_sample_cbd_coeffs when sec_sample_cbd_coeffs_vld = '1' else (1 => (x"00" & sec_sample_bounded_coeffs(1)), 0 => (x"00" & sec_sample_bounded_coeffs(0)));
    sampled_fifo_din_vld <= sec_sample_cbd_coeffs_vld or sec_sample_bounded_coeffs_vld;

    sampled_fifo_dout_rdy <= sec_conversion_s_axis_tready;

    coeffs_vld <= sec_conversion_m_axis_tvalid or rej_ntt_valid_coeffs_vld;

    rej_next <= (not rej_ntt_valid_coeffs_vld) or coeffs_next when mode_shift_reg(mode_shift_reg'left)(1 downto 0) = "00" else
        sec_sample_cbd_s_axis_tready and (not sample_cbd_loaded_all) when mode_shift_reg(mode_shift_reg'left)(2) = '0' else
        sec_sample_bounded_s_axis_tready;

    coeffs_next <= not coeffs_vld_r or m_axis_tready;

    coeffs_count_last <= '1' when coeffs_count = 63 or (mode_shift_reg(mode_shift_reg'left - 1)(2) = '0' and coeffs_count = 31) else '0';

    proc_out: process(clk) is
        variable bound: std_logic_vector(23 downto 0);
    begin
        if rising_edge(clk) then
            if coeffs_next = '1' then
                if sec_conversion_m_axis_tvalid = '1' then
                    -- TODO: unify these subtractions..
                    if sec_conversion_m_axis_tuser(3) = '1' then
                        -- adjust sampled coefficients to <-ETA; ETA>
                        if mode = '0' then
                            bound := x"000002";
                        else
                            bound := x"000004";
                        end if;

                        for j in 0 to 3 loop
                            coeffs_r(0)(23 + 24 * j downto 24 * j) <= dilithium_sub_reduce(bound, sec_conversion_m_axis_tdata(0)(23 + 24 * j downto 24 * j));
                            coeffs_r(1)(23 + 24 * j downto 24 * j) <= dilithium_sub_reduce(x"000000", sec_conversion_m_axis_tdata(1)(23 + 24 * j downto 24 * j));
                        end loop;
                    else
                        -- `sec_sample_cbd` outputs coefficients + 3, so subtract the 3
                        -- for j in 0 to 3 loop
                            -- coeffs_r(0)(23 + 24 * j downto 24 * j) <= sub_reduce(sec_conversion_m_axis_tdata(0)(23 + 24 * j downto 24 * j), x"003003", '1');
                            -- coeffs_r(1)(23 + 24 * j downto 24 * j) <= sec_conversion_m_axis_tdata(1)(23 + 24 * j downto 24 * j);
                        -- end loop;
                        for j in 0 to 7 loop
                            coeffs_r(0)(11 + 12 * j downto 12 * j) <= kyber_sub_reduce(sec_conversion_m_axis_tdata(0)(11 + 12 * j downto 12 * j), x"003");
                            coeffs_r(1)(11 + 12 * j downto 12 * j) <= sec_conversion_m_axis_tdata(1)(11 + 12 * j downto 12 * j);
                        end loop;
                    end if;
                else
                    coeffs_r <= (1 => (95 downto 0 => '0'), 0 => rej_ntt_valid_coeffs(95 downto 0));
                end if;

                coeffs_count_last_r <= coeffs_count_last and coeffs_vld;
            end if;

            if rst = '1' then
                coeffs_vld_r <= '0';

                coeffs_count <= 0;
            else
                if coeffs_vld = '1' then
                    coeffs_vld_r <= '1';
                elsif m_axis_tready = '1' then
                    coeffs_vld_r <= '0';
                end if;

                if (coeffs_vld and coeffs_next) = '1' then
                    if coeffs_count_last = '1' then
                        coeffs_count <= 0;
                    else
                        coeffs_count <= coeffs_count + 1;
                    end if;
                end if;
            end if;
        end if;
    end process;

    process(clk) is
    begin
        if rising_edge(clk) then
            if reg_ready_m_axis_tvalid = '1' then
                mode_shift_reg(mode_shift_reg'left) <= reg_ready_m_axis_tuser;
            end if;

            mode_shift_reg(mode_shift_reg'left - 1 downto 0) <= mode_shift_reg(mode_shift_reg'left downto 1);
        end if;
    end process;
end;
