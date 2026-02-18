library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.reduce_pkg.all;

entity poly_mul_top is
port (
    clk: in std_logic;
    rst: in std_logic;

    top_mode: in std_logic;

    coeffs_in: in std_logic_vector(95 downto 0);
    coeffs_in_vld: in std_logic;

    coeffs_out: out std_logic_vector(95 downto 0);
    coeffs_out_vld: out std_logic
);
end;

architecture behav of poly_mul_top is
    signal bram_wea: std_logic;
    signal bram_dina, bram_doutb: std_logic_vector(95 downto 0);
    signal bram_addra, bram_addrb: std_logic_vector(6 downto 0);

    signal poly_mul_start, poly_mul_rdy, poly_mul_vld: std_logic;
    signal poly_mul_mode: std_logic_vector(2 downto 0);
    signal poly_mul_coeffs_wea: std_logic;
    signal poly_mul_coeffs_in, poly_mul_coeffs_out: std_logic_vector(95 downto 0);
    signal poly_mul_coeffs_addra, poly_mul_coeffs_addrb: std_logic_vector(6 downto 0);

    signal loading: std_logic;
    signal reading: std_logic;
    -- compensate BRAM delay
    signal reading_shift_reg: std_logic_vector(1 downto 0);

    signal running: std_logic;

    signal counter: unsigned(6 downto 0);
    signal counter_last: std_logic;

    signal mode, write_mode: natural range 0 to 4;
begin
    coeffs_out <= bram_doutb;
    coeffs_out_vld <= reading_shift_reg(0);

    coeffs_bram: entity work.bram
    generic map (
        DATA_WIDTH => 96,
        DATA_DEPTH => 128
    )
    port map (
        clk => clk,

        wea => bram_wea,
        reb => '1',

        dina => bram_dina,
        doutb => bram_doutb,

        addra => bram_addra,
        addrb => bram_addrb
    );

    bram_wea <= loading or poly_mul_coeffs_wea;

    bram_dina <= coeffs_in when loading = '1' else poly_mul_coeffs_out;

    bram_addra <= std_logic_vector(counter) when loading = '1' else
        '1' & poly_mul_coeffs_addra(5 downto 0) when top_mode = '1' and (write_mode = 1 or write_mode = 4) else
        "01" & poly_mul_coeffs_addra(4 downto 0) when write_mode = 1 or write_mode = 4 else
        poly_mul_coeffs_addra;
    bram_addrb <= std_logic_vector(counter) when reading = '1' else
        '1' & poly_mul_coeffs_addrb(5 downto 0) when top_mode = '1' and (mode = 1 or mode = 4) else
        "01" & poly_mul_coeffs_addrb(4 downto 0) when mode = 1 or mode = 4 else
        poly_mul_coeffs_addrb;

    poly_mul: entity work.poly_mul
    port map (
        clk => clk,
        rst => rst,

        start => poly_mul_start,
        rdy => poly_mul_rdy,

        vld => poly_mul_vld,

        mode => poly_mul_mode,

        inplace_coeffs => (others => '0'),
        inplace_op => (others => '0'),

        coeffs_wea => poly_mul_coeffs_wea,

        coeffs_dina => poly_mul_coeffs_out,
        coeffs_doutb => poly_mul_coeffs_in,

        coeffs_addra => poly_mul_coeffs_addra,
        coeffs_addrb => poly_mul_coeffs_addrb
    );

    with mode select poly_mul_mode <=
        top_mode & "00" when 0 | 1,
        top_mode & "10" when 2,
        top_mode & "11" when 3,
        top_mode & "01" when 4;

    poly_mul_coeffs_in <= bram_doutb;

    counter_last <= and counter when top_mode = '1' else and counter(5 downto 0);

    process(clk) is
    begin
        if rising_edge(clk) then
            reading_shift_reg <= reading & reading_shift_reg(reading_shift_reg'left downto 1);

            if (counter_last and loading) = '1' or ((poly_mul_rdy and running) = '1' and write_mode /= 4) then
                poly_mul_start <= '1';
            else
                poly_mul_start <= '0';
            end if;

            if rst = '1' then
                loading <= '1';
                reading <= '0';
                running <= '0';

                counter <= (others => '0');

                mode <= 0;
                write_mode <= 0;
            else
                if poly_mul_start = '1' then
                    running <= '1';
                elsif poly_mul_rdy = '1' then
                    running <= '0';
                end if;

                if ((loading and coeffs_in_vld) or reading) then
                    counter <= counter + 1;
                end if;

                if counter_last = '1' then
                    counter <= (others => '0');

                    loading <= reading;
                    reading <= '0';
                end if;

                if (poly_mul_rdy and running) = '1' then
                    if mode = 4 then
                        reading <= '1';
                        mode <= 0;
                    elsif mode = 2 and top_mode = '1' then
                        mode <= 4;
                    else
                        mode <= mode + 1;
                    end if;
                end if;

                if poly_mul_vld = '1' then
                    if write_mode = 4 then
                        write_mode <= 0;
                    elsif write_mode = 2 and top_mode = '1' then
                        write_mode <= 4;
                    else
                        write_mode <= write_mode + 1;
                    end if;
                end if;
            end if;
        end if;
    end process;
end;
