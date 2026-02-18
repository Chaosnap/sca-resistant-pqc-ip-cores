-- Copyright (C) 2024 Patrik Dobias <xdobia13@vut.cz>
-- Released for the non-commercial use only. For licensing, please contact <malina@vut.cz>

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.params_pkg.all;
use work.reduce_pkg.all;

-- decodes stream of coefficients and stores them in BRAM
entity decode is
port (
    clk: in std_logic;
    rst: in std_logic;

    -- stream of bytes that should be decoded to coefficients
    s_axis_tdata: in std_logic_vector(63 downto 0);
    -- determine mode of decoding
    -- 0000 - kyber t (12b per coeff)
    -- 0001 - kyber u (11b per coeff)
    -- 0010 - kyber u (10b per coeff)
    -- 0011 - kyber v (5b per coeff)
    -- 0100 - kyber v (4b per coeff)
    -- 0101 - kyber m (1b per coeff)
    -- 0111 - kyber s (12b per coeff)
    -- 1000 - dilithium (20b per coeff)
    -- 1001 - dilithium (18b per coeff)
    -- 1010 - dilithium t0 (13b per coeff)
    -- 1011 - dilithium t1 (10b per coeff)
    -- 1100 - dilithium w1 (6b per coeff) - probably not needed? this size is only used for encoding
    -- 1101 - dilithium w1 (4b per coeff) - probably not needed? this size is only used for encoding
    -- 1110 - dilithium s1/s2 (4b per coeff)
    -- 1111 - dilithium s1/s2 (3b per coeff)
    s_axis_tuser: in std_logic_vector(3 downto 0);
    s_axis_tvalid: in std_logic;
    s_axis_tready: out std_logic;

    -- stream of decoded coefficients
    m_axis_tdata: out std_logic_vector(95 downto 0);
    m_axis_tuser: out std_logic_vector(3 downto 0);
    m_axis_tvalid: out std_logic;
    m_axis_tready: in std_logic
);
end;

architecture behav of decode is
    type x48b_array_t is array(natural range <>) of std_logic_vector(47 downto 0);

    signal reg_ready_m_axis_tdata: std_logic_vector(63 downto 0);
    signal reg_ready_m_axis_tuser: std_logic_vector(3 downto 0);
    signal reg_ready_m_axis_tvalid, reg_ready_m_axis_tready: std_logic;

    signal mode, coeffs_mode: std_logic_vector(3 downto 0);
    -- rotated input data
    -- rotated_bytes(0) <= reg_ready_m_axis_tdata(47 downto 0);
    -- rotated_bytes(1) <= reg_ready_m_axis_tdata(31 downto 0) & reg_ready_m_axis_tdata(63 downto 48);
    -- rotated_bytes(2) <= reg_ready_m_axis_tdata(15 downto 0) & reg_ready_m_axis_tdata(63 downto 32);
    -- rotated_bytes(3) <= reg_ready_m_axis_tdata(63 downto 16);
    signal bytes_rotated: x48b_array_t(3 downto 0);
    -- correctly selected bytes for coefficients reading
    signal bytes: std_logic_vector(47 downto 0);
    -- 3 downto 0 determines how `rotated_bytes` will be used to create `bytes`
    -- 4 indicates `bytes` should be additionally shifted by 2 during decoding of 13b (dilithium)
    signal bytes_mux: std_logic_vector(4 downto 0);
    signal bytes_vld, bytes_next: std_logic;

    -- coeffs signals
    signal coeffs: std_logic_vector(95 downto 0);
    signal coeffs_vld: std_logic_vector(1 downto 0);
    signal coeffs_next: std_logic;

    signal state: std_logic_vector(6 downto 0);
begin
    m_axis_tdata <= coeffs;
    m_axis_tuser <= coeffs_mode;
    m_axis_tvalid <= coeffs_vld(1);

    reg_ready: entity work.reg_ready
    generic map (
        DATA_WIDTH => 64,
        USER_WIDTH => 4
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

    reg_ready_m_axis_tready <= bytes_next;

    -- determine if we are ready for next input
    proc_bytes_next: process(all) is
    begin
        case state is
            when "0000000" =>
                case reg_ready_m_axis_tuser is
                    when "0100" | "0101" | "1010" | "1100" | "1101" | "1110" | "1111" => bytes_next <= '0';
                    when others => bytes_next <= not bytes_vld or coeffs_next;
                end case;
            -- 12b (kyber)
            when "0000001" | "0000011" => bytes_next <= not bytes_vld or coeffs_next;
            -- 11b (kyber)
            when "0000100" | "0000110" | "0000111" | "0001001" | "0001010" | "0001100" | "0001101" | "0001111" | "0010000" | "0010010" => bytes_next <= not bytes_vld or coeffs_next;
            -- 10b, 5b (kyber), 20b (dilithium), 10b (dilithium)
            when "0010100" | "0010101" | "0010111" | "0011001" => bytes_next <= not bytes_vld or coeffs_next;
            -- 4b (kyber)
            when "0011010" => bytes_next <= not bytes_vld or coeffs_next;
            -- 1b (kyber)
            when "0100001" => bytes_next <= not bytes_vld or coeffs_next;
            -- 18b (dilithium)
            when "0100011" | "0100101" | "0100111" | "0101000" | "0101010" | "0101100" | "0101110" | "0110000" => bytes_next <= not bytes_vld or coeffs_next;
            -- 13b (dilithium)
            when "0110001" | "0110011" | "0110110" | "0111000" | "0111011" | "0111101" | "1000000" | "1000010" | "1000101" | "1000111" | "1001010" | "1001100" | "1001111" => bytes_next <= not bytes_vld or coeffs_next;
            -- 6b (dilithium)
            when "1010000" | "1010011" | "1010110" => bytes_next <= not bytes_vld or coeffs_next;
            -- 4b (dilithium)
            when "1011001" => bytes_next <= not bytes_vld or coeffs_next;
            -- 3b (dilithium)
            when "1011101" | "1100010" | "1101000" => bytes_next <= not bytes_vld or coeffs_next;
            when others => bytes_next <= '0';
        end case;
    end process;

    proc_bytes: process(clk) is
    begin
        if rising_edge(clk) then
            if (reg_ready_m_axis_tvalid and (not bytes_vld or coeffs_next)) = '1' then
                mode <= reg_ready_m_axis_tuser;

                -- determine which `bytes_rotated` should be updated based on current state
                -- also determine next `bytes_mux` base on current state
                case state is
                    when "0000000" =>
                        bytes_mux <= "00000";
                        bytes_rotated(0)(47 downto 0) <= reg_ready_m_axis_tdata(47 downto 0);
                        bytes_rotated(1)(15 downto 0) <= reg_ready_m_axis_tdata(63 downto 48);
                    -- 12b (kyber)
                    when "0000001" =>
                        bytes_mux <= "00100";
                        bytes_rotated(1)(47 downto 16) <= reg_ready_m_axis_tdata(31 downto 0);
                        bytes_rotated(2)(31 downto 0) <= reg_ready_m_axis_tdata(63 downto 32);
                    when "0000010" =>
                        bytes_mux <= "01000";
                        bytes_rotated(2)(47 downto 32) <= reg_ready_m_axis_tdata(15 downto 0);
                        bytes_rotated(3)(47 downto 0) <= reg_ready_m_axis_tdata(63 downto 16);
                    when "0000011" =>
                        bytes_mux <= "01100";
                    -- 11b (kyber)
                    when "0000100" =>
                        bytes_mux <= "00001";
                        bytes_rotated(1)(47 downto 16) <= reg_ready_m_axis_tdata(31 downto 0);
                        bytes_rotated(2)(31 downto 0) <= reg_ready_m_axis_tdata(63 downto 32);
                    when "0000101" =>
                        bytes_mux <= "00110";
                        bytes_rotated(2)(47 downto 32) <= reg_ready_m_axis_tdata(15 downto 0);
                    when "0000110" =>
                        bytes_mux <= "01011";
                        bytes_rotated(1)(15 downto 0) <= reg_ready_m_axis_tdata(63 downto 48);
                        bytes_rotated(3)(47 downto 0) <= reg_ready_m_axis_tdata(63 downto 16);
                    when "0000111" =>
                        bytes_mux <= "00100";
                        bytes_rotated(1)(47 downto 16) <= reg_ready_m_axis_tdata(31 downto 0);
                        bytes_rotated(2)(31 downto 0) <= reg_ready_m_axis_tdata(63 downto 32);
                    when "0001000" =>
                        bytes_mux <= "00101";
                        bytes_rotated(2)(47 downto 32) <= reg_ready_m_axis_tdata(15 downto 0);
                        bytes_rotated(3)(47 downto 0) <= reg_ready_m_axis_tdata(63 downto 16);
                    when "0001001" =>
                        bytes_mux <= "01010";
                    when "0001010" =>
                        bytes_mux <= "01111";
                        bytes_rotated(0)(47 downto 0) <= reg_ready_m_axis_tdata(47 downto 0);
                        bytes_rotated(2)(31 downto 0) <= reg_ready_m_axis_tdata(63 downto 32);
                    when "0001011" =>
                        bytes_mux <= "01000";
                        bytes_rotated(2)(47 downto 32) <= reg_ready_m_axis_tdata(15 downto 0);
                    when "0001100" =>
                        bytes_mux <= "01001";
                        bytes_rotated(3)(47 downto 0) <= reg_ready_m_axis_tdata(63 downto 16);
                    when "0001101" =>
                        bytes_mux <= "01110";
                        bytes_rotated(0)(47 downto 0) <= reg_ready_m_axis_tdata(47 downto 0);
                        bytes_rotated(1)(15 downto 0) <= reg_ready_m_axis_tdata(63 downto 48);
                    when "0001110" =>
                        bytes_mux <= "00011";
                        bytes_rotated(1)(47 downto 16) <= reg_ready_m_axis_tdata(31 downto 0);
                        bytes_rotated(3)(47 downto 0) <= reg_ready_m_axis_tdata(63 downto 16);
                    when "0001111" =>
                        bytes_mux <= "01100";
                    when "0010000" =>
                        bytes_mux <= "01101";
                        bytes_rotated(0)(47 downto 0) <= reg_ready_m_axis_tdata(47 downto 0);
                        bytes_rotated(1)(15 downto 0) <= reg_ready_m_axis_tdata(63 downto 48);
                    when "0010001" =>
                        bytes_mux <= "00010";
                        bytes_rotated(1)(47 downto 16) <= reg_ready_m_axis_tdata(31 downto 0);
                    when "0010010" =>
                        bytes_mux <= "00111";
                        bytes_rotated(2)(31 downto 0) <= reg_ready_m_axis_tdata(63 downto 32);
                    -- 10b, 5b (kyber), 20b, 10b (dilithium)
                    when "0010011" =>
                        bytes_mux <= "00010";
                        bytes_rotated(1)(47 downto 16) <= reg_ready_m_axis_tdata(31 downto 0);
                        bytes_rotated(3)(47 downto 0) <= reg_ready_m_axis_tdata(63 downto 16);
                    when "0010100" =>
                        bytes_mux <= "01100";
                    when "0010101" =>
                        bytes_mux <= "01110";
                        bytes_rotated(0)(47 downto 0) <= reg_ready_m_axis_tdata(47 downto 0);
                        bytes_rotated(2)(31 downto 0) <= reg_ready_m_axis_tdata(63 downto 32);
                    when "0010110" =>
                        bytes_mux <= "01000";
                        bytes_rotated(2)(47 downto 32) <= reg_ready_m_axis_tdata(15 downto 0);
                    when "0010111" =>
                        bytes_mux <= "01010";
                        bytes_rotated(1)(15 downto 0) <= reg_ready_m_axis_tdata(63 downto 48);
                        bytes_rotated(3)(47 downto 0) <= reg_ready_m_axis_tdata(63 downto 16);
                    when "0011000" =>
                        bytes_mux <= "00100";
                        bytes_rotated(1)(47 downto 16) <= reg_ready_m_axis_tdata(31 downto 0);
                    when "0011001" =>
                        bytes_mux <= "00110";
                        bytes_rotated(2)(31 downto 0) <= reg_ready_m_axis_tdata(63 downto 32);
                    -- 4b (kyber)
                    when "0011010" =>
                        bytes_mux <= "01000";
                        bytes_rotated(2)(31 downto 0) <= reg_ready_m_axis_tdata(63 downto 32);
                    -- 1b (kyber)
                    when "0011011" =>
                        bytes_mux <= "01010";
                        bytes_rotated(2)(47 downto 32) <= reg_ready_m_axis_tdata(15 downto 0);
                    when "0011100" =>
                        bytes_mux <= "01100";
                        bytes_rotated(3)(47 downto 0) <= reg_ready_m_axis_tdata(63 downto 16);
                    when "0011101" =>
                        bytes_mux <= "00110";
                        bytes_rotated(1)(47 downto 16) <= reg_ready_m_axis_tdata(31 downto 0);
                    when "0011110" =>
                        bytes_mux <= "01000";
                        bytes_rotated(2)(31 downto 0) <= reg_ready_m_axis_tdata(63 downto 32);
                    when "0011111" =>
                        bytes_mux <= "00010";
                    when "0100000" =>
                        bytes_mux <= "00100";
                    when "0100001" =>
                        bytes_mux <= "01110";
                    -- 18b (dilithium)
                    when "0100010" =>
                        bytes_mux <= "00011";
                        bytes_rotated(1)(47 downto 16) <= reg_ready_m_axis_tdata(31 downto 0);
                        bytes_rotated(2)(47 downto 32) <= reg_ready_m_axis_tdata(15 downto 0);
                    when "0100011" =>
                        bytes_mux <= "01010";
                        bytes_rotated(0)(47 downto 0) <= reg_ready_m_axis_tdata(47 downto 0);
                        bytes_rotated(1)(15 downto 0) <= reg_ready_m_axis_tdata(63 downto 48);
                        bytes_rotated(3)(47 downto 0) <= reg_ready_m_axis_tdata(63 downto 16);
                    when "0100100" =>
                        bytes_mux <= "00001";
                        bytes_rotated(1)(47 downto 16) <= reg_ready_m_axis_tdata(31 downto 0);
                    when "0100101" =>
                        bytes_mux <= "01100";
                        bytes_rotated(3)(47 downto 0) <= reg_ready_m_axis_tdata(63 downto 16);
                    when "0100110" =>
                        bytes_mux <= "01111";
                        bytes_rotated(0)(47 downto 0) <= reg_ready_m_axis_tdata(47 downto 0);
                        bytes_rotated(1)(47 downto 16) <= reg_ready_m_axis_tdata(31 downto 0);
                        bytes_rotated(2)(31 downto 0) <= reg_ready_m_axis_tdata(63 downto 32);
                    when "0100111" =>
                        bytes_mux <= "00110";
                        bytes_rotated(3)(47 downto 0) <= reg_ready_m_axis_tdata(63 downto 16);
                    when "0101000" =>
                        bytes_mux <= "01101";
                        bytes_rotated(0)(47 downto 0) <= reg_ready_m_axis_tdata(47 downto 0);
                        bytes_rotated(2)(31 downto 0) <= reg_ready_m_axis_tdata(63 downto 32);
                    when "0101001" =>
                        bytes_mux <= "01000";
                        bytes_rotated(2)(47 downto 32) <= reg_ready_m_axis_tdata(15 downto 0);
                    when "0101010" =>
                        bytes_mux <= "01011";
                        bytes_rotated(0)(47 downto 0) <= reg_ready_m_axis_tdata(47 downto 0);
                        bytes_rotated(1)(15 downto 0) <= reg_ready_m_axis_tdata(63 downto 48);
                        bytes_rotated(3)(47 downto 0) <= reg_ready_m_axis_tdata(63 downto 16);
                    when "0101011" =>
                        bytes_mux <= "00010";
                        bytes_rotated(1)(47 downto 16) <= reg_ready_m_axis_tdata(31 downto 0);
                        bytes_rotated(2)(47 downto 32) <= reg_ready_m_axis_tdata(15 downto 0);
                    when "0101100" =>
                        bytes_mux <= "01001";
                        bytes_rotated(1)(15 downto 0) <= reg_ready_m_axis_tdata(63 downto 48);
                        bytes_rotated(3)(47 downto 0) <= reg_ready_m_axis_tdata(63 downto 16);
                    when "0101101" =>
                        bytes_mux <= "00100";
                        bytes_rotated(1)(47 downto 16) <= reg_ready_m_axis_tdata(31 downto 0);
                    when "0101110" =>
                        bytes_mux <= "00111";
                        bytes_rotated(2)(31 downto 0) <= reg_ready_m_axis_tdata(63 downto 32);
                        bytes_rotated(3)(47 downto 0) <= reg_ready_m_axis_tdata(63 downto 16);
                    when "0101111" =>
                        bytes_mux <= "01110";
                        bytes_rotated(0)(47 downto 0) <= reg_ready_m_axis_tdata(47 downto 0);
                        bytes_rotated(1)(47 downto 16) <= reg_ready_m_axis_tdata(31 downto 0);
                        bytes_rotated(2)(31 downto 0) <= reg_ready_m_axis_tdata(63 downto 32);
                    when "0110000" =>
                        bytes_mux <= "00101";
                        bytes_rotated(2)(47 downto 32) <= reg_ready_m_axis_tdata(15 downto 0);
                    -- 13b (dilithium)
                    when "0110001" =>
                        bytes_mux <= "10110";
                        bytes_rotated(1)(47 downto 16) <= reg_ready_m_axis_tdata(31 downto 0);
                        bytes_rotated(2)(31 downto 0) <= reg_ready_m_axis_tdata(63 downto 32);
                        bytes_rotated(3)(47 downto 0) <= reg_ready_m_axis_tdata(63 downto 16);
                    when "0110010" =>
                        bytes_mux <= "01111";
                        bytes_rotated(0)(47 downto 0) <= reg_ready_m_axis_tdata(47 downto 0);
                    when "0110011" =>
                        bytes_mux <= "11001";
                        bytes_rotated(1)(15 downto 0) <= reg_ready_m_axis_tdata(63 downto 48);
                        bytes_rotated(2)(47 downto 0) <= reg_ready_m_axis_tdata(15 downto 0) & reg_ready_m_axis_tdata(63 downto 32);
                        bytes_rotated(3)(47 downto 0) <= reg_ready_m_axis_tdata(63 downto 16);
                    when "0110100" =>
                        bytes_mux <= "00010";
                        bytes_rotated(1)(47 downto 16) <= reg_ready_m_axis_tdata(31 downto 0);
                    when "0110101" =>
                        bytes_mux <= "10000";
                        bytes_rotated(0)(47 downto 0) <= reg_ready_m_axis_tdata(47 downto 0);
                        bytes_rotated(3)(47 downto 0) <= reg_ready_m_axis_tdata(63 downto 16);
                    when "0110110" =>
                        bytes_mux <= "00101";
                        bytes_rotated(2)(31 downto 0) <= reg_ready_m_axis_tdata(63 downto 32);
                    when "0110111" =>
                        bytes_mux <= "11111";
                        bytes_rotated(0)(47 downto 0) <= reg_ready_m_axis_tdata(47 downto 0);
                    when "0111000" =>
                        bytes_mux <= "01100";
                        bytes_rotated(1)(15 downto 0) <= reg_ready_m_axis_tdata(63 downto 48);
                        bytes_rotated(3)(47 downto 0) <= reg_ready_m_axis_tdata(63 downto 16);
                    when "0111001" =>
                        bytes_mux <= "10010";
                        bytes_rotated(1)(47 downto 16) <= reg_ready_m_axis_tdata(31 downto 0);
                    when "0111010" =>
                        bytes_mux <= "01011";
                        bytes_rotated(2)(47 downto 32) <= reg_ready_m_axis_tdata(15 downto 0);
                        bytes_rotated(3)(47 downto 0) <= reg_ready_m_axis_tdata(63 downto 16);
                    when "0111011" =>
                        bytes_mux <= "10101";
                        bytes_rotated(2)(31 downto 0) <= reg_ready_m_axis_tdata(63 downto 32);
                    when "0111100" =>
                        bytes_mux <= "01110";
                        bytes_rotated(0)(47 downto 0) <= reg_ready_m_axis_tdata(47 downto 0);
                    when "0111101" =>
                        bytes_mux <= "11100";
                        bytes_rotated(1)(15 downto 0) <= reg_ready_m_axis_tdata(63 downto 48);
                        bytes_rotated(3)(47 downto 0) <= reg_ready_m_axis_tdata(63 downto 16);
                    when "0111110" =>
                        bytes_mux <= "00001";
                        bytes_rotated(1)(47 downto 16) <= reg_ready_m_axis_tdata(31 downto 0);
                    when "0111111" =>
                        bytes_mux <= "11011";
                        bytes_rotated(2)(47 downto 0) <= reg_ready_m_axis_tdata(15 downto 0) & reg_ready_m_axis_tdata(63 downto 32);
                        bytes_rotated(3)(47 downto 0) <= reg_ready_m_axis_tdata(63 downto 16);
                    when "1000000" =>
                        bytes_mux <= "01000";
                        bytes_rotated(3)(47 downto 0) <= reg_ready_m_axis_tdata(63 downto 16);
                    when "1000001" =>
                        bytes_mux <= "11110";
                        bytes_rotated(0)(47 downto 0) <= reg_ready_m_axis_tdata(47 downto 0);
                        bytes_rotated(1)(47 downto 16) <= reg_ready_m_axis_tdata(31 downto 0);
                    when "1000010" =>
                        bytes_mux <= "00111";
                        bytes_rotated(1)(15 downto 0) <= reg_ready_m_axis_tdata(63 downto 48);
                        bytes_rotated(2)(31 downto 0) <= reg_ready_m_axis_tdata(63 downto 32);
                    when "1000011" =>
                        bytes_mux <= "10001";
                        bytes_rotated(1)(47 downto 16) <= reg_ready_m_axis_tdata(31 downto 0);
                        bytes_rotated(2)(47 downto 32) <= reg_ready_m_axis_tdata(15 downto 0);
                    when "1000100" =>
                        bytes_mux <= "01010";
                        bytes_rotated(3)(47 downto 0) <= reg_ready_m_axis_tdata(63 downto 16);
                    when "1000101" =>
                        bytes_mux <= "11000";
                        bytes_rotated(2)(31 downto 0) <= reg_ready_m_axis_tdata(63 downto 32);
                    when "1000110" =>
                        bytes_mux <= "01101";
                        bytes_rotated(0)(47 downto 0) <= reg_ready_m_axis_tdata(47 downto 0);
                    when "1000111" =>
                        bytes_mux <= "10111";
                        bytes_rotated(1)(47 downto 0) <= reg_ready_m_axis_tdata(31 downto 0) & reg_ready_m_axis_tdata(63 downto 48);
                        bytes_rotated(2)(31 downto 0) <= reg_ready_m_axis_tdata(63 downto 32);
                    when "1001000" =>
                        bytes_mux <= "00100";
                        bytes_rotated(1)(47 downto 16) <= reg_ready_m_axis_tdata(31 downto 0);
                    when "1001001" =>
                        bytes_mux <= "11010";
                        bytes_rotated(2)(47 downto 32) <= reg_ready_m_axis_tdata(15 downto 0);
                        bytes_rotated(3)(47 downto 0) <= reg_ready_m_axis_tdata(63 downto 16);
                    when "1001010" =>
                        bytes_mux <= "00011";
                        bytes_rotated(0)(47 downto 0) <= reg_ready_m_axis_tdata(47 downto 0);
                        bytes_rotated(1)(15 downto 0) <= reg_ready_m_axis_tdata(63 downto 48);
                    when "1001011" =>
                        bytes_mux <= "11101";
                        bytes_rotated(0)(47 downto 0) <= reg_ready_m_axis_tdata(47 downto 0);
                    when "1001100" =>
                        bytes_mux <= "00110";
                        bytes_rotated(1)(47 downto 0) <= reg_ready_m_axis_tdata(31 downto 0) & reg_ready_m_axis_tdata(63 downto 48);
                        bytes_rotated(2)(31 downto 0) <= reg_ready_m_axis_tdata(63 downto 32);
                    when "1001101" =>
                        bytes_mux <= "10100";
                        bytes_rotated(0)(47 downto 0) <= reg_ready_m_axis_tdata(47 downto 0);
                        bytes_rotated(1)(47 downto 16) <= reg_ready_m_axis_tdata(31 downto 0);
                    when "1001110" =>
                        bytes_mux <= "01001";
                        bytes_rotated(2)(47 downto 32) <= reg_ready_m_axis_tdata(15 downto 0);
                        bytes_rotated(3)(47 downto 0) <= reg_ready_m_axis_tdata(63 downto 16);
                    when "1001111" =>
                        bytes_mux <= "10011";
                        bytes_rotated(1)(15 downto 0) <= reg_ready_m_axis_tdata(63 downto 48);
                    -- 6b (dilithium)
                    when "1010000" =>
                        bytes_mux <= "00110";
                        bytes_rotated(1)(47 downto 16) <= reg_ready_m_axis_tdata(31 downto 0);
                        bytes_rotated(2)(31 downto 0) <= reg_ready_m_axis_tdata(63 downto 32);
                    when "1010001" =>
                        bytes_mux <= "00100";
                        bytes_rotated(1)(47 downto 16) <= reg_ready_m_axis_tdata(31 downto 0);
                    when "1010010" =>
                        bytes_mux <= "01010";
                        bytes_rotated(2)(47 downto 32) <= reg_ready_m_axis_tdata(15 downto 0);
                        bytes_rotated(3)(47 downto 0) <= reg_ready_m_axis_tdata(63 downto 16);
                    when "1010011" =>
                        bytes_mux <= "01000";
                        bytes_rotated(2)(31 downto 0) <= reg_ready_m_axis_tdata(63 downto 32);
                    when "1010100" =>
                        bytes_mux <= "01110";
                        bytes_rotated(0)(47 downto 0) <= reg_ready_m_axis_tdata(47 downto 0);
                    when "1010101" =>
                        bytes_mux <= "01100";
                        bytes_rotated(3)(47 downto 0) <= reg_ready_m_axis_tdata(63 downto 16);
                    when "1010110" =>
                        bytes_mux <= "00010";
                        bytes_rotated(1)(15 downto 0) <= reg_ready_m_axis_tdata(63 downto 48);
                    -- 4b (dilithium)
                    when "1010111" =>
                        bytes_mux <= "01100";
                        bytes_rotated(3)(47 downto 0) <= reg_ready_m_axis_tdata(63 downto 16);
                    when "1011000" =>
                        bytes_mux <= "01000";
                        bytes_rotated(2)(31 downto 0) <= reg_ready_m_axis_tdata(63 downto 32);
                    when "1011001" =>
                        bytes_mux <= "00100";
                    -- 3b (dilithium)
                    when "1011010" =>
                        bytes_mux <= "01001";
                        bytes_rotated(2)(47 downto 32) <= reg_ready_m_axis_tdata(15 downto 0);
                        bytes_rotated(3)(47 downto 0) <= reg_ready_m_axis_tdata(63 downto 16);
                    when "1011011" =>
                        bytes_mux <= "00110";
                        bytes_rotated(1)(47 downto 16) <= reg_ready_m_axis_tdata(31 downto 0);
                        bytes_rotated(2)(31 downto 0) <= reg_ready_m_axis_tdata(63 downto 32);
                    when "1011100" =>
                        bytes_mux <= "00011";
                    when "1011101" =>
                        bytes_mux <= "00100";
                    when "1011110" =>
                        bytes_mux <= "01101";
                        bytes_rotated(0)(47 downto 0) <= reg_ready_m_axis_tdata(47 downto 0);
                        bytes_rotated(1)(47 downto 16) <= reg_ready_m_axis_tdata(31 downto 0);
                    when "1011111" =>
                        bytes_mux <= "01010";
                        bytes_rotated(2)(47 downto 32) <= reg_ready_m_axis_tdata(15 downto 0);
                        bytes_rotated(3)(47 downto 0) <= reg_ready_m_axis_tdata(63 downto 16);
                    when "1100000" =>
                        bytes_mux <= "00111";
                    when "1100001" =>
                        bytes_mux <= "01000";
                        bytes_rotated(2)(31 downto 0) <= reg_ready_m_axis_tdata(63 downto 32);
                    when "1100010" =>
                        bytes_mux <= "00001";
                        bytes_rotated(1)(15 downto 0) <= reg_ready_m_axis_tdata(63 downto 48);
                    when "1100011" =>
                        bytes_mux <= "01110";
                        bytes_rotated(0)(47 downto 0) <= reg_ready_m_axis_tdata(47 downto 0);
                        bytes_rotated(2)(47 downto 32) <= reg_ready_m_axis_tdata(15 downto 0);
                    when "1100100" =>
                        bytes_mux <= "01011";
                    when "1100101" =>
                        bytes_mux <= "01100";
                        bytes_rotated(3)(47 downto 0) <= reg_ready_m_axis_tdata(63 downto 16);
                    when "1100110" =>
                        bytes_mux <= "00101";
                        bytes_rotated(1)(47 downto 16) <= reg_ready_m_axis_tdata(31 downto 0);
                        bytes_rotated(2)(31 downto 0) <= reg_ready_m_axis_tdata(63 downto 32);
                    when "1100111" =>
                        bytes_mux <= "00010";
                        bytes_rotated(1)(15 downto 0) <= reg_ready_m_axis_tdata(63 downto 48);
                    when "1101000" =>
                        bytes_mux <= "01111";
                    when others =>
                end case;
            end if;

            if rst = '1' then
                bytes_vld <= '0';
                state <= "0000000";
            else
                if reg_ready_m_axis_tvalid = '1' then
                    bytes_vld <= '1';
                elsif coeffs_next = '1' then
                    bytes_vld <= '0';
                end if;

                if (reg_ready_m_axis_tvalid and (not bytes_vld or coeffs_next)) = '1' then
                    -- decoding starts for all modes at same state
                    -- then it will move to state based on mode and start incrementing state
                    -- when it reaches final state for the mode, it will start again
                    case state is
                        when "0000000" =>
                            case reg_ready_m_axis_tuser is
                                when "0001" => state <= "0000100";
                                when "0010" => state <= "0010011";
                                when "0011" => state <= "0010011";
                                when "0100" => state <= "0011010";
                                when "0101" => state <= "0011011";
                                when "1000" => state <= "0010011";
                                when "1001" => state <= "0100010";
                                when "1010" => state <= "0110001";
                                when "1011" => state <= "0010011";
                                when "1100" => state <= "1010000";
                                when "1101" | "1110" => state <= "1010111";
                                when "1111" => state <= "1011010";
                                when others => state <= "0000001";
                            end case;
                        when "0000011" | "0010010" | "0011001" | "0011010" | "0100001" | "0110000" | "1001111" | "1010110" | "1011001" | "1101000" =>
                            state <= "0000000";
                        when others =>
                            state <= std_logic_vector(unsigned(state) + 1);
                    end case;
                end if;
            end if;
        end if;
    end process;

    -- access `bytes_rotated` by index, it syntetises better (lower LUTs usage)
    with bytes_mux(1 downto 0) select bytes <=
        bytes_rotated(to_integer(unsigned(bytes_mux(3 downto 2)))) when "00",
        x"0" & bytes_rotated((to_integer(unsigned(bytes_mux(3 downto 2))) + 1) mod 4)(39 downto 0) & bytes_rotated(to_integer(unsigned(bytes_mux(3 downto 2))))(47 downto 44) when "01",
        x"0" & bytes_rotated((to_integer(unsigned(bytes_mux(3 downto 2))) + 1) mod 4)(35 downto 0) & bytes_rotated(to_integer(unsigned(bytes_mux(3 downto 2))))(47 downto 40) when "10",
        x"0" & bytes_rotated((to_integer(unsigned(bytes_mux(3 downto 2))) + 1) mod 4)(31 downto 0) & bytes_rotated(to_integer(unsigned(bytes_mux(3 downto 2))))(47 downto 36) when others;

    coeffs_next <= not coeffs_vld(1) or m_axis_tready;

    proc_coeffs: process(clk) is
    begin
        if rising_edge(clk) then
            if (bytes_vld and coeffs_next) = '1' then
                coeffs_mode <= mode;

                coeffs(95 downto 0) <= (others => '0');

                if coeffs_vld(0) = '1' then
                    coeffs(47 downto 0) <= coeffs(95 downto 48);
                end if;

                -- get coefficients from bytes based on current mode
                for i in 0 to 3 loop
                    case mode is
                        -- 11b (kyber)
                        when "0001" =>
                            coeffs(10 + 12 * (i + 4) downto 12 * (i + 4)) <= bytes(10 + 11 * i downto 11 * i);
                        -- 10b (kyber)
                        when "0010" =>
                            coeffs(9 + 12 * (i + 4) downto 12 * (i + 4)) <= bytes(9 + 10 * i downto 10 * i);
                        -- 5b (kyber)
                        when "0011" =>
                            coeffs(4 + 12 * i downto 12 * i) <= bytes(4 + 5 * i downto 5 * i);
                            coeffs(4 + 12 * (i + 4) downto 12 * (i + 4)) <= bytes(4 + 5 * (i + 4) downto 5 * (i + 4));
                        -- 4b (kyber)
                        when "0100" =>
                            coeffs(3 + 12 * i downto 12 * i) <= bytes(3 + 4 * i downto 4 * i);
                            coeffs(3 + 12 * (i + 4) downto 12 * (i + 4)) <= bytes(3 + 4 * (i + 4) downto 4 * (i + 4));
                        -- 1b (kyber)
                        when "0101" =>
                            coeffs(12 * i) <= bytes(i);
                            coeffs(12 * (i + 4)) <= bytes(i + 4);
                        -- 20b (dilithium)
                        when "1000" =>
                            if i < 2 then
                                coeffs(19 + 24 * (i + 2) downto 24 * (i + 2)) <= bytes(19 + 20 * i downto 20 * i);
                            end if;
                        -- 18b (dilithium)
                        when "1001" =>
                            if i < 2 then
                                coeffs(17 + 24 * (i + 2) downto 24 * (i + 2)) <= bytes(17 + 18 * i downto 18 * i);
                            end if;
                        -- 13b (dilithium)
                        when "1010" =>
                            if i < 2 then
                                if bytes_mux(4) = '0' then
                                    coeffs(12 + 24 * (i + 2) downto 24 * (i + 2)) <= bytes(12 + 13 * i downto 13 * i);
                                else
                                    coeffs(12 + 24 * (i + 2) downto 24 * (i + 2)) <= bytes(14 + 13 * i downto 2 + 13 * i);
                                end if;
                            end if;
                        -- 10b (dilithium)
                        when "1011" =>
                            if i < 2 then
                                coeffs(9 + 24 * i downto 24 * i) <= bytes(9 + 10 * i downto 10 * i);
                                coeffs(9 + 24 * (i + 2) downto 24 * (i + 2)) <= bytes(9 + 10 * (i + 2) downto 10 * (i + 2));
                            end if;
                        -- 6b (dilithium)
                        when "1100" =>
                            if i < 2 then
                                coeffs(5 + 24 * i downto 24 * i) <= bytes(5 + 6 * i downto 6 * i);
                                coeffs(5 + 24 * (i + 2) downto 24 * (i + 2)) <= bytes(5 + 6 * (i + 2) downto 6 * (i + 2));
                            end if;
                        -- 4b (dilithium)
                        when "1101" | "1110" =>
                            if i < 2 then
                                coeffs(3 + 24 * i downto 24 * i) <= bytes(3 + 4 * i downto 4 * i);
                                coeffs(3 + 24 * (i + 2) downto 24 * (i + 2)) <= bytes(3 + 4 * (i + 2) downto 4 * (i + 2));
                            end if;
                        -- 3b (dilithium)
                        when "1111" =>
                            if i < 2 then
                                coeffs(2 + 24 * i downto 24 * i) <= bytes(2 + 3 * i downto 3 * i);
                                coeffs(2 + 24 * (i + 2) downto 24 * (i + 2)) <= bytes(2 + 3 * (i + 2) downto 3 * (i + 2));
                            end if;
                        when others =>
                            coeffs(11 + 12 * (i + 4) downto 12 * (i + 4)) <= bytes(11 + 12 * i downto 12 * i);
                    end case;
                end loop;
            end if;

            if rst = '1' then
                coeffs_vld <= "00";
            else
                if (bytes_vld and coeffs_next) = '1' then
                    coeffs_vld <= coeffs_vld(0) & not coeffs_vld(0);

                    -- for some modes we are able to generate all coefficients every cycle
                    case mode is
                        when "0011" | "0100" | "0101" | "1011" | "1100" | "1101" | "1110" | "1111" => coeffs_vld <= "10";
                        when others =>
                    end case;
                elsif (coeffs_vld(1) and coeffs_next) = '1' then
                    coeffs_vld <= "00";
                end if;
            end if;
        end if;
    end process;
end;
