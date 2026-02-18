-- Copyright (C) 2024 Patrik Dobias <xdobia13@vut.cz>
-- Released for the non-commercial use only. For licensing, please contact <malina@vut.cz>

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.params_pkg.all;
use work.reduce_pkg.all;

-- compresses or decompresses coefficients, also performs decompose/power2round operation in dilithium
entity compress is
port (
    clk: in std_logic;
    rst: in std_logic;

    -- stream of compressed/decompressed coefficients
    s_axis_tdata: in std_logic_vector(95 downto 0);
    -- determine mode of compression
    -- 5 downto 4:
    -- 00 - compress
    -- 01 - decompress
    -- 10 - high bits (only dilithium)
    -- 11 - low bits (only dilithium)
    -- 3 downto 0:
    -- compress, decompress
    -- 0000 - kyber t/s (12b per coeff)
    -- 0001 - kyber u (11b per coeff)
    -- 0010 - kyber u (10b per coeff)
    -- 0011 - kyber v (5b per coeff)
    -- 0100 - kyber v (4b per coeff)
    -- 0101 - kyber m (1b per coeff)
    -- 1000 - dilithium z/y (20b per coeff)
    -- 1001 - dilithium z/y (18b per coeff)
    -- 1010 - dilithium t0 (13b per coeff)
    -- 1011 - dilithium t1 (10b per coeff) (nothing happens, this is here only for better compatibility)
    -- 1110 - dilithium s1/s2 (4b per coeff)
    -- 1111 - dilithium s1/s2 (3b per coeff)
    -- high bits
    -- 1011 - dilithium t1 (10b per coeff)
    -- 1000 - dilithium w1 (6b per coeff)
    -- 1001 - dilithium w1 (4b per coeff)
    -- low bits
    -- 1011 - dilithium t0 (13b per coeff)
    -- 1000 - dilithium w0 (18b per coeff)
    -- 1001 - dilithium w0 (20b per coeff)
    s_axis_tuser: in std_logic_vector(5 downto 0);
    s_axis_tvalid: in std_logic;
    s_axis_tready: out std_logic;

    -- stream of compressed/decompressed coefficients
    m_axis_tdata: out std_logic_vector(95 downto 0);
    m_axis_low_bits_tdata: out std_logic_vector(95 downto 0);
    m_axis_tuser: out std_logic_vector(5 downto 0);
    m_axis_tvalid: out std_logic;
    m_axis_tready: in std_logic
);
end;

architecture behav of compress is
    type x6b_shift_reg_t is array(natural range <>) of std_logic_vector(5 downto 0);
    type x96b_shift_reg_t is array(natural range <>) of std_logic_vector(95 downto 0);

    signal reg_ready_m_axis_tdata: std_logic_vector(95 downto 0);
    signal reg_ready_m_axis_tuser: std_logic_vector(5 downto 0);
    signal reg_ready_m_axis_tvalid, reg_ready_m_axis_tready: std_logic;

    -- used for first cycle computations
    signal t_reg: unsigned(127 downto 0);

    -- kyber signals
    signal kyber_compressed, kyber_decompressed: std_logic_vector(95 downto 0);

    -- dilithium signals
    signal dilithium_compressed, dilithium_low_bits: std_logic_vector(95 downto 0);

    signal out_data: std_logic_vector(95 downto 0);

    -- shift registers
    signal vld_shift_reg: std_logic_vector(3 downto 0);
    signal mode_shift_reg: x6b_shift_reg_t(3 downto 0);
    signal x_shift_reg: x96b_shift_reg_t(1 downto 0);
begin
    m_axis_tdata <= out_data;
    m_axis_tuser <= mode_shift_reg(0);
    m_axis_tvalid <= vld_shift_reg(0);

    -- register ready signal for better timing
    reg_ready: entity work.reg_ready
    generic map (
        DATA_WIDTH => 96,
        USER_WIDTH => 6
    )
    port map (
        clk => clk,
        rst => rst,

        s_axis_tdata => s_axis_tdata,
        s_axis_tuser => s_axis_tuser,
        s_axis_tvalid => s_axis_tvalid,
        s_axis_tready => s_axis_tready,

        m_axis_tdata => reg_ready_m_axis_tdata,
        m_axis_tuser => reg_ready_m_axis_tuser,
        m_axis_tvalid => reg_ready_m_axis_tvalid,
        m_axis_tready => reg_ready_m_axis_tready
    );

    reg_ready_m_axis_tready <= (not (and vld_shift_reg)) or m_axis_tready;

    proc_t: process(clk) is
        variable x: unsigned(11 downto 0);
        variable x2: unsigned(23 downto 0);
        variable tmp: unsigned(24 downto 0);
    begin
        if rising_edge(clk) then
            if (vld_shift_reg(vld_shift_reg'left) and (not (and vld_shift_reg(vld_shift_reg'left - 1 downto 0)) or m_axis_tready)) = '1' then
                if mode_shift_reg(mode_shift_reg'left)(3) = '0' then
                    -- for kyber t = 13 * x
                    for i in 0 to 7 loop
                        x := unsigned(x_shift_reg(x_shift_reg'left)(11 + 12 * i downto 12 * i));

                        t_reg(15 + 16 * i downto 16 * i) <= ('0' & x & "000") + (x & "00") + x;
                    end loop;
                else
                    -- dilithium t = high_bits
                    -- t(15 + 16 * i) indicates if x1 has special value leading to setting high_bits to 0 and subtracting 1 from low_bits
                    for i in 0 to 3 loop
                        x2 := unsigned(x_shift_reg(x_shift_reg'left)(23 + 24 * i downto 24 * i));

                        if mode_shift_reg(mode_shift_reg'left)(0) = '0' then
                            tmp := (x2 & '0') + x2(23 downto 1) + x2(23 downto 2);
                        else
                            tmp := '0' & x2;
                        end if;

                        tmp := tmp + (tmp(24 downto 19) & (8 downto 0 => '0')) + x"400ff";

                        t_reg(5 + 16 * i downto 16 * i) <= tmp(24 downto 19);

                        -- indicate that lower_bits should be negative
                        if mode_shift_reg(mode_shift_reg'left)(1 downto 0) = "11" then
                            t_reg(15 + 16 * i) <= x2(12) and (or x2(11 downto 0));
                        else
                            if mode_shift_reg(mode_shift_reg'left)(0) = '0' then
                                if tmp(24 downto 19) = x"2c" then
                                    t_reg(15 + 16 * i) <= '1';
                                else
                                    t_reg(15 + 16 * i) <= '0';
                                end if;
                            else
                                t_reg(15 + 16 * i) <= tmp(23);
                            end if;
                        end if;
                    end loop;
                end if;
            end if;
        end if;
    end process;

    proc_kyber_compressed: process(clk) is
        variable t: unsigned(15 downto 0);
        variable addition: unsigned(20 downto 0);
        variable tmp: unsigned(21 downto 0);
    begin
        if rising_edge(clk) then
            if mode_shift_reg(mode_shift_reg'left - 1)(4 downto 3) = "00" and (vld_shift_reg(vld_shift_reg'left - 1) and (not (and vld_shift_reg(vld_shift_reg'left - 2 downto 0)) or m_axis_tready)) = '1' then
                case mode_shift_reg(mode_shift_reg'left - 1)(2 downto 0) is
                    when "001" => addition := '0' & x"00400";
                    when "010" => addition := '0' & x"00800";
                    when "011" => addition := '0' & x"10000";
                    when "100" => addition := '0' & x"20000";
                    when "101" => addition := '1' & x"00000";
                    when others =>
                end case;

                for i in 0 to 7 loop
                    t := t_reg(15 + 16 * i downto 16 * i);
                    tmp := (unsigned(x_shift_reg(x_shift_reg'left - 1)(11 + 12 * i downto 12 * i)) & (9 downto 0 => '0')) + (t(15 downto 0) & "0000") + (t & '0') + t(15 downto 3) + t(15 downto 6) + t(15 downto 7) + addition;

                    kyber_compressed(11 + 12 * i downto 12 * i) <= x"000";

                    case mode_shift_reg(mode_shift_reg'left - 1)(2 downto 0) is
                        when "000" => kyber_compressed(11 + 12 * i downto 12 * i) <= x_shift_reg(x_shift_reg'left - 1)(11 + 12 * i downto 12 * i);
                        when "001" => kyber_compressed(10 + 12 * i downto 12 * i) <= std_logic_vector(tmp(21 downto 11));
                        when "010" => kyber_compressed(9 + 12 * i downto 12 * i) <= std_logic_vector(tmp(21 downto 12));
                        when "011" => kyber_compressed(4 + 12 * i downto 12 * i) <= std_logic_vector(tmp(21 downto 17));
                        when "100" => kyber_compressed(3 + 12 * i downto 12 * i) <= std_logic_vector(tmp(21 downto 18));
                        -- this is not correctly compressed, but when encoding only LSB is used, which is correct and during decapsulation it is needed to immediately decompress this, so it does it in one step
                        when "101" => kyber_compressed(11 + 12 * i downto 12 * i) <= x"681" and (11 downto 0 => tmp(21));
                        when others =>
                    end case;
                end loop;
            end if;
        end if;
    end process;

    proc_kyber_decompressed: process(clk) is
        variable x: unsigned(2 downto 0);
        variable t, tmp: unsigned(14 downto 0);
    begin
        if rising_edge(clk) then
            if mode_shift_reg(mode_shift_reg'left - 1)(4 downto 3) = "10" and (vld_shift_reg(vld_shift_reg'left - 1) and (not (and vld_shift_reg(vld_shift_reg'left - 2 downto 0)) or m_axis_tready)) = '1' then
                for i in 0 to 7 loop
                    case mode_shift_reg(mode_shift_reg'left - 1)(2 downto 0) is
                        when "001" =>
                            x := unsigned(x_shift_reg(x_shift_reg'left - 1)(10 + 12 * i downto 8 + 12 * i));
                            t := t_reg(14 + 16 * i downto 16 * i);
                        when "010" =>
                            x := unsigned(x_shift_reg(x_shift_reg'left - 1)(9 + 12 * i downto 8 + 12 * i)) & '0';
                            t := t_reg(13 + 16 * i downto 16 * i) & '0';
                        when "011" =>
                            x := unsigned(x_shift_reg(x_shift_reg'left - 1)(4 + 12 * i downto 4 + 12 * i)) & "00";
                            t := t_reg(8 + 16 * i downto 16 * i) & "000000";
                        when "100" =>
                            x := unsigned(x_shift_reg(x_shift_reg'left - 1)(3 + 12 * i downto 3 + 12 * i)) & "00";
                            t := t_reg(7 + 16 * i downto 16 * i) & "0000000";
                        when "101" =>
                            x := x_shift_reg(x_shift_reg'left - 1)(12 * i) & "00";
                            t := t_reg(4 + 16 * i downto 16 * i) & "0000000000";
                        when others =>
                    end case;

                    tmp := x + t + 4;

                    if mode_shift_reg(mode_shift_reg'left - 1)(2 downto 0) = "000" then
                        kyber_decompressed(11 + 12 * i downto 12 * i) <= x_shift_reg(x_shift_reg'left - 1)(11 + 12 * i downto 12 * i);
                    else
                        kyber_decompressed(11 + 12 * i downto 12 * i) <= std_logic_vector(tmp(14 downto 3));
                    end if;
                end loop;
            end if;
        end if;
    end process;

    proc_dilithium_compressed: process(clk) is
        variable x, bound: std_logic_vector(23 downto 0);
    begin
        if rising_edge(clk) then
            if mode_shift_reg(mode_shift_reg'left - 1)(3) = '1' and (vld_shift_reg(vld_shift_reg'left - 1) and (not (and vld_shift_reg(vld_shift_reg'left - 2 downto 0)) or m_axis_tready)) = '1' then
                for i in 0 to 3 loop
                    x := x_shift_reg(x_shift_reg'left - 1)(23 + 24 * i downto 24 * i);

                    if mode_shift_reg(mode_shift_reg'left - 1)(5) = '0' then
                        case mode_shift_reg(mode_shift_reg'left - 1)(2 downto 0) is
                            when "000" => bound := x"080000";
                            when "001" => bound := x"020000";
                            when "010" => bound := x"001000";
                            when "110" => bound := x"000004";
                            when "111" => bound := x"000002";
                            when others =>
                        end case;

                        dilithium_compressed(23 + 24 * i downto 24 * i) <= dilithium_sub_reduce(bound, x);

                        if mode_shift_reg(mode_shift_reg'left - 1)(2 downto 0) = "011" then
                            dilithium_compressed(23 + 24 * i downto 24 * i) <= x(10 downto 0) & (12 downto 0 => '0');
                        end if;
                    else
                        dilithium_compressed(23 + 24 * i downto 24 * i) <= (others => '0');

                        if mode_shift_reg(mode_shift_reg'left - 1)(1 downto 0) = "11" then
                            dilithium_compressed(10 + 24 * i downto 24 * i) <= std_logic_vector(unsigned(x(23 downto 13)) + t_reg(15 + 16 * i));
                        else
                            if t_reg(15 + 16 * i) = '1' then
                                dilithium_compressed(5 + 24 * i downto 24 * i) <= (others => '0');
                            else
                                dilithium_compressed(5 + 24 * i downto 24 * i) <= std_logic_vector(t_reg(5 + 16 * i downto 16 * i));
                            end if;
                        end if;
                    end if;
                end loop;
            end if;
        end if;
    end process;

    proc_dilithium_low_bits: process(clk) is
        variable x: std_logic_vector(23 downto 0);
        variable x1: unsigned(5 downto 0);
        variable tmp: signed(23 downto 0);
    begin
        if rising_edge(clk) then
            if (mode_shift_reg(mode_shift_reg'left - 1)(5) and mode_shift_reg(mode_shift_reg'left - 1)(3)) = '1' and (vld_shift_reg(vld_shift_reg'left - 1) and (not (and vld_shift_reg(vld_shift_reg'left - 2 downto 0)) or m_axis_tready)) = '1' then
                for i in 0 to 3 loop
                    x := x_shift_reg(x_shift_reg'left - 1)(23 + 24 * i downto 24 * i);
                    x1 := t_reg(5 + 16 * i downto 16 * i);

                    if mode_shift_reg(mode_shift_reg'left - 1)(1 downto 0) = "11" then
                        tmp := (signed(x(23 downto 13)) & '0' & x"000") + ('0' & t_reg(15 + 16 * i) & '0' & x"000");
                    else
                        if mode_shift_reg(mode_shift_reg'left - 1)(0) = '0' then
                            tmp := signed((x1 & (17 downto 0 => '0')) - (x1 & (15 downto 0 => '0')) - (x1 & (11 downto 0 => '0')) - (x1 & (10 downto 0 => '0'))) - signed(t_reg(15 + 16 * i downto 15 + 16 * i));
                        else
                            tmp := signed((x1(4 downto 0) & (18 downto 0 => '0')) - (x1(4 downto 0) & (8 downto 0 => '0'))) - signed(t_reg(15 + 16 * i downto 15 + 16 * i));
                        end if;
                    end if;

                    dilithium_low_bits(23 + 24 * i downto 24 * i) <= dilithium_sub_reduce(x, std_logic_vector(tmp));
                end loop;
            end if;

            if (mode_shift_reg(mode_shift_reg'left - 2)(5) and mode_shift_reg(mode_shift_reg'left - 2)(3)) = '1' and (vld_shift_reg(vld_shift_reg'left - 2) and (not (and vld_shift_reg(vld_shift_reg'left - 3 downto 0)) or m_axis_tready)) = '1' then
                m_axis_low_bits_tdata <= dilithium_low_bits;
            end if;
        end if;
    end process;

    proc_out: process(clk) is
    begin
        if rising_edge(clk) then
            if (vld_shift_reg(1) and (not vld_shift_reg(0) or m_axis_tready)) = '1' then
                if mode_shift_reg(1)(3) = '0' then
                    if mode_shift_reg(1)(4) = '0' then
                        out_data <= kyber_compressed;
                    else
                        out_data <= kyber_decompressed;
                    end if;
                else
                    out_data <= dilithium_compressed;
                end if;
            end if;
        end if;
    end process;

    process(clk) is
    begin
        if rising_edge(clk) then
            if (reg_ready_m_axis_tvalid and (not (and vld_shift_reg) or m_axis_tready)) = '1' then
                x_shift_reg(x_shift_reg'left) <= reg_ready_m_axis_tdata;
                mode_shift_reg(mode_shift_reg'left) <= reg_ready_m_axis_tuser;
            end if;

            for i in 0 to x_shift_reg'left - 1 loop
                if (vld_shift_reg(vld_shift_reg'left - i) and (not (and vld_shift_reg(vld_shift_reg'left - i - 1 downto 0)) or m_axis_tready)) = '1' then
                    x_shift_reg(x_shift_reg'left - i - 1) <= x_shift_reg(x_shift_reg'left - i);
                end if;
            end loop;

            for i in 0 to mode_shift_reg'left - 1 loop
                if (vld_shift_reg(vld_shift_reg'left - i) and (not (and vld_shift_reg(vld_shift_reg'left - i - 1 downto 0)) or m_axis_tready)) = '1' then
                    mode_shift_reg(mode_shift_reg'left - i - 1) <= mode_shift_reg(mode_shift_reg'left - i);
                end if;
            end loop;

            if rst = '1' then
                vld_shift_reg <= (others => '0');
            else
                if reg_ready_m_axis_tvalid = '1' then
                    vld_shift_reg(vld_shift_reg'left) <= '1';
                elsif (not (and vld_shift_reg(vld_shift_reg'left - 1 downto 0)) or m_axis_tready) = '1' then
                    vld_shift_reg(vld_shift_reg'left) <= '0';
                end if;

                for i in 0 to vld_shift_reg'left - 2 loop
                    if vld_shift_reg(vld_shift_reg'left - i) = '1' then
                        vld_shift_reg(vld_shift_reg'left - i - 1) <= '1';
                    elsif (not (and vld_shift_reg(vld_shift_reg'left - i - 2 downto 0)) or m_axis_tready) = '1' then
                        vld_shift_reg(vld_shift_reg'left - i - 1) <= '0';
                    end if;
                end loop;

                if vld_shift_reg(1) = '1' then
                    vld_shift_reg(0) <= '1';
                elsif m_axis_tready = '1' then
                    vld_shift_reg(0) <= '0';
                end if;
            end if;
        end if;
    end process;
end;
