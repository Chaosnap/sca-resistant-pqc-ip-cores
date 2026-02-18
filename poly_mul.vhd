-- Copyright (C) 2024 Patrik Dobias <xdobia13@vut.cz>
-- Released for the non-commercial use only. For licensing, please contact <malina@vut.cz>

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.params_pkg.all;
use work.reduce_pkg.all;

-- computes NTT/INTT of a polynomial, it also supports polynomial multiplication for resource sharing (all operations need `butterfly` units)
entity poly_mul is
generic (
    BRAM_DELAY: natural := 2
);
port (
    clk: in std_logic;
    rst: in std_logic;

    -- indicates that new coefficients are ready for processing
    start: in std_logic;
    -- indicates that component is ready to accept new coefficients
    rdy: out std_logic;

    -- indicates that component finished computation
    -- will be active only for one clock cycle
    vld: out std_logic;

    -- describing what operation is this component used in:
    -- - 000 => kyber NTT
    -- - 001 => kyber INTT
    -- - 010 => kyber polynomial multiplication (part 1)
    -- - 011 => kyber polynomial multiplication (part 2)
    -- - 100 => dilithium NTT
    -- - 101 => dilithium INTT
    -- - 110 => dilithium polynomial multiplication
    -- must be valid when `start` is active
    mode: in std_logic_vector(2 downto 0);

    first_iteration: out std_logic;
    last_iteration: out std_logic;

    inplace_coeffs: in std_logic_vector(95 downto 0);
    inplace_op: in std_logic_vector(1 downto 0);
    inplace_next: out std_logic;

    -- bram interface for polynomial coefficients
    -- it expects 8 (4) following coefficients, they will stay in same order after it finishes
    coeffs_wea: out std_logic;

    coeffs_dina: out std_logic_vector(95 downto 0);
    coeffs_doutb: in std_logic_vector(95 downto 0);

    coeffs_addra: out std_logic_vector(6 downto 0);
    coeffs_addrb: out std_logic_vector(6 downto 0)
);
end;

architecture behav of poly_mul is
    type array_48b_t is array(integer range <>) of std_logic_vector(47 downto 0);
    type array_24b_t is array(integer range <>) of std_logic_vector(23 downto 0);
    type array_12b_t is array(integer range <>) of std_logic_vector(11 downto 0);

    -- maps counter to correct memory address based on current iteration
    function get_address(iteration: natural range 0 to 9; counter: std_logic_vector(6 downto 0)) return std_logic_vector is
    begin
        case iteration is
            when 0 | 1 | 2 => return counter(6 downto 0);
            when 3 => return counter(6 downto 2) & counter(0) & counter(1);
            when 4 => return counter(6 downto 3) & counter(0) & counter(2 downto 1);
            when 5 => return counter(6 downto 4) & counter(0) & counter(3 downto 1);
            when 6 => return counter(6 downto 5) & counter(0) & counter(4 downto 1);
            when 7 => return counter(6) & counter(0) & counter(5 downto 1);
            when 8 => return counter(6) & counter(0) & counter(5 downto 1);
            when 9 => return counter(0) & counter(6 downto 1);
        end case;
    end;

    -- using separate "ROM"s does not use BRAM to implement, but about 100 LUTs, which seems ok to me
    constant DILITHIUM_ZETAS: array_24b_t(0 to 191) := (
        x"000000", x"495e02", x"397567", x"396569", x"4f062b", x"53df73", x"4fe033", x"4f066b",
        x"76b1ae", x"360dd5", x"28edb0", x"207fe4", x"397283", x"70894a", x"088192", x"6d3dc8",
        x"4c7294", x"41e0b4", x"28a3d2", x"66528a", x"4a18a7", x"794034", x"0a52ee", x"6b7d81",
        x"4e9f1d", x"1a2877", x"2571df", x"1649ee", x"7611bd", x"492bb7", x"2af697", x"22d8d5",
        x"36f72a", x"30911e", x"29d13f", x"492673", x"50685f", x"2010a2", x"3887f7", x"11b2c3",
        x"0603a4", x"0e2bed", x"10b72c", x"4a5f35", x"1f9d15", x"428cd4", x"3177f4", x"20e612",
        x"341c1d", x"1ad873", x"736681", x"49553f", x"3952f6", x"62564a", x"65ad05", x"439a1c",
        x"53aa5f", x"30b622", x"087f38", x"3b0e6d", x"2c83da", x"1c496e", x"330e2b", x"1c5b70",
        x"2ee3f1", x"137eb9", x"57a930", x"3ac6ef", x"3fd54c", x"4eb2ea", x"503ee1", x"7bb175",
        x"2648b4", x"1ef256", x"1d90a2", x"45a6d4", x"2ae59b", x"52589c", x"6ef1f5", x"3f7288",
        x"175102", x"075d59", x"1187ba", x"52aca9", x"773e9e", x"0296d8", x"2592ec", x"4cff12",
        x"404ce8", x"4aa582", x"1e54e6", x"4f16c1", x"1a7e79", x"03978f", x"4e4817", x"31b859",
        x"5884cc", x"1b4827", x"5b63d0", x"5d787a", x"35225e", x"400c7e", x"6c09d1", x"5bd532",
        x"6bc4d3", x"258ecb", x"2e534c", x"097a6c", x"3b8820", x"6d285c", x"2ca4f8", x"337caa",
        x"14b2a0", x"558536", x"28f186", x"55795d", x"4af670", x"234a86", x"75e826", x"78de66",
        x"05528c", x"7adf59", x"0f6e17", x"5bf3da", x"459b7e", x"628b34", x"5dbecb", x"1a9e7b",

        x"0006d9", x"574b3c", x"289838", x"7ef8f5", x"120a23", x"09b7ff", x"437ff8", x"4dc04e",
        x"7f735d", x"0f66d5", x"61ab98", x"437f31", x"662960", x"28de06", x"49b0e3", x"7c0db3",
        x"409ba9", x"21762a", x"246e39", x"7bc759", x"392db2", x"12eb67", x"30c31c", x"13232e",
        x"2dbfcb", x"7e832c", x"6b3375", x"6be1cc", x"78e00d", x"3da604", x"1f1d68", x"7361b8",
        x"671ac7", x"5ba4ff", x"08f201", x"080e6d", x"695688", x"2603bd", x"07c017", x"74d0bd",
        x"519573", x"2867ba", x"58018c", x"0b7009", x"3cbd37", x"673957", x"196926", x"11c14e",
        x"3cf42f", x"6af66c", x"3352d6", x"085260", x"2f6316", x"07c0f1", x"0d1ff0", x"0223d4",
        x"5e8885", x"23fc65", x"51e0ed", x"2ca5e6", x"7b4064", x"433aac", x"1cfe14", x"10170e"
    );

    constant DILITHIUM_ZETAS2: array_24b_t(0 to 63) := (
        x"6257c5", x"69a8ef", x"64b5fe", x"2a4e78", x"0154a8", x"435e87", x"5cd5b4", x"4728af",
        x"0c8d0d", x"5a6d80", x"185d96", x"468298", x"4bd579", x"465d8d", x"09b434", x"5a68b0",
        x"64d3d5", x"658591", x"48c39b", x"4f5859", x"230923", x"454df2", x"285424", x"7faf80",
        x"022a0b", x"26587a", x"095b76", x"5e061e", x"628c37", x"4ae53c", x"6330bb", x"5ea06c",
        x"201fc6", x"60d772", x"6de024", x"56038e", x"1e6d3e", x"6a9dfa", x"6dbfd4", x"63e1e3",
        x"7ab60d", x"2decd4", x"3f4cf5", x"427e23", x"273333", x"1a4b5d", x"1ef206", x"4c76c8",
        x"7fb19a", x"2e1669", x"034760", x"741e78", x"6f0a11", x"776d0b", x"345824", x"68c559",
        x"2faa32", x"5e6942", x"65adb3", x"79e1fe", x"35e1dd", x"464ade", x"73f1ce", x"74b6d7"
    );

    constant KYBER_ZETAS: array_12b_t(0 to 95) := (
        x"001", x"6c1", x"a14", x"cd9", x"a52", x"276", x"769", x"350",
        x"426", x"77f", x"0c1", x"31d", x"ae2", x"cbc", x"239", x"6d2",
        x"128", x"98f", x"53b", x"5c4", x"be6", x"038", x"8c0", x"535",
        x"592", x"82e", x"217", x"b42", x"959", x"b3f", x"7b6", x"335",
        x"121", x"14b", x"cb5", x"6dc", x"4ad", x"900", x"8e5", x"807",
        x"28a", x"7b9", x"9d1", x"278", x"b31", x"021", x"528", x"77b",
        x"90f", x"59b", x"327", x"1c4", x"59e", x"b34", x"5fe", x"962",
        x"a57", x"a39", x"5c9", x"288", x"9aa", x"c26", x"4cb", x"38e",

        x"011", x"247", x"665", x"8f0", x"581", x"cd1", x"2f4", x"bc7",
        x"6a7", x"ae5", x"737", x"5b5", x"3ab", x"985", x"2dd", x"10c",
        x"630", x"7f5", x"177", x"82a", x"427", x"ad5", x"833", x"9a2",
        x"af4", x"193", x"477", x"ad7", x"6ba", x"752", x"83e", x"375"
    );

    constant KYBER_ZETAS2: array_12b_t(0 to 31) := (
        x"ac9", x"a59", x"2d3", x"44c", x"a66", x"0e9", x"86c", x"bea",
        x"673", x"6fd", x"3b8", x"a7f", x"904", x"954", x"921", x"281",
        x"8fa", x"c94", x"9f5", x"66d", x"13f", x"2f5", x"231", x"a22",
        x"444", x"402", x"866", x"376", x"4bc", x"405", x"b77", x"86a"
    );

    -- use `idle_shift_reg` to compensate bram delay
    signal idle: std_logic;
    signal idle_shift_reg: std_logic_vector(BRAM_DELAY - 1 downto 0);

    signal inplace_mux: std_logic;

    -- butterfly signals
    signal butterfly0_a, butterfly0_b: std_logic_vector(23 downto 0);
    signal butterfly0_zeta: std_logic_vector(23 downto 0);
    signal butterfly0_c, butterfly0_d: std_logic_vector(23 downto 0);
    signal butterfly0_inplace_coeffs: std_logic_vector(23 downto 0);
    signal butterfly0_inplace_next: std_logic;

    signal butterfly1_a, butterfly1_b: std_logic_vector(23 downto 0);
    signal butterfly1_zeta: std_logic_vector(23 downto 0);
    signal butterfly1_c, butterfly1_d: std_logic_vector(23 downto 0);
    signal butterfly1_inplace_coeffs: std_logic_vector(23 downto 0);

    signal butterfly_vld_in, butterfly_vld_out: std_logic;

    -- head reorder
    signal head_reorder_mux_en: std_logic;
    signal head_reorder_mux_shift_reg, head_reorder_zero_iteration_shift_reg: std_logic_vector(BRAM_DELAY - 1 downto 0);
    signal head_reorder_coeffs_reg: std_logic_vector(95 downto 0);

    -- tail reorder
    signal tail_reorder_mux: std_logic;
    signal tail_reorder_coeffs_reg: std_logic_vector(95 downto 0);

    signal zeta_index_en: std_logic;
    signal zeta_index_no_mode, zeta_index: natural range 0 to 191;
    signal zeta_shift_reg: array_48b_t(BRAM_DELAY - 1 downto 0);

    -- coeffs signals
    signal last_iteration_reg: std_logic;
    signal coeffs_wea_reg: std_logic;
    signal coeffs_addra_reg: std_logic_vector(6 downto 0);

    -- current iteration and counter of read and write coefficients
    signal write_counter, read_counter: unsigned(6 downto 0);
    -- iterations 0-6(7 for dilithium) => iterations of NTT/INTT, 8 => multiplication for kyber, 9 => multiplication for dilithium
    signal write_iteration, read_iteration: natural range 0 to 9;
    signal write_iteration_no_mode, read_iteration_no_mode: natural range 0 to 9;
    signal write_iteration_target, read_iteration_target: natural range 6 to 7;

    signal write_counter_last, read_counter_last: std_logic;
    signal write_iteration_last, read_iteration_last: std_logic;

    -- delay modes for reading and writing coefficients
    signal read_mode: std_logic_vector(2 downto 0);
    signal write_mode: std_logic_vector(2 downto 0);

    signal vld_reg: std_logic;
begin
    rdy <= idle and idle_shift_reg(0);
    vld <= vld_reg;

    first_iteration <= not read_mode(1) when read_iteration_no_mode = 0 else '0';
    last_iteration <= last_iteration_reg;

    inplace_next <= butterfly0_inplace_next and inplace_mux;

    coeffs_wea <= coeffs_wea_reg;
    coeffs_dina <= butterfly1_c & butterfly0_c & tail_reorder_coeffs_reg(47 downto 0) when tail_reorder_mux = '1' else tail_reorder_coeffs_reg;

    coeffs_addra <= coeffs_addra_reg;
    coeffs_addrb <= get_address(read_iteration, std_logic_vector(read_counter));

    proc_inplace: process(clk) is
    begin
        if rising_edge(clk) then
            if rst = '1' then
                inplace_mux <= '0';
            else
                if butterfly0_inplace_next = '1' then
                    inplace_mux <= not inplace_mux;
                end if;
            end if;
        end if;
    end process;

    butterfly0: entity work.butterfly
    port map (
        clk => clk,
        rst => rst,

        mode => read_mode,

        A => butterfly0_a,
        B => butterfly0_b,

        zeta => butterfly0_zeta,

        C => butterfly0_c,
        D => butterfly0_d,

        inplace_coeffs => butterfly0_inplace_coeffs,
        inplace_op => inplace_op,
        inplace_next => butterfly0_inplace_next,

        vld_in => butterfly_vld_in,
        vld_out => butterfly_vld_out
    );

    butterfly0_inplace_coeffs <= inplace_coeffs(23 downto 0) when inplace_mux = '0' else inplace_coeffs(71 downto 48);

    proc_butterfly0: process(all) is
    begin
        case read_mode is
            -- NTT
            when "000" | "100" =>
                butterfly0_a <= head_reorder_coeffs_reg(23 downto 0);
                butterfly0_b <= coeffs_doutb(23 downto 0) when head_reorder_mux_shift_reg(0) = '1' else head_reorder_coeffs_reg(71 downto 48);

                butterfly0_zeta <= zeta_shift_reg(0)(23 downto 0);
            -- kyber INTT
            when "001" =>
                butterfly0_a <= head_reorder_coeffs_reg(23 downto 0);
                butterfly0_b <= coeffs_doutb(23 downto 0) when head_reorder_mux_shift_reg(0) = '1' else head_reorder_coeffs_reg(71 downto 48);

                butterfly0_zeta <= zeta_shift_reg(0)(11 downto 0) & zeta_shift_reg(0)(23 downto 12);
            -- dilithium INTT
            when "101" =>
                butterfly0_a <= coeffs_doutb(23 downto 0) when head_reorder_mux_shift_reg(0) = '1' else head_reorder_coeffs_reg(71 downto 48);
                butterfly0_b <= head_reorder_coeffs_reg(23 downto 0);

                butterfly0_zeta <= sub_reduce(x"000000", zeta_shift_reg(0)(47 downto 24), '1');
            -- kyber multiplication (part 1)
            when "010" =>
                butterfly0_a <= head_reorder_coeffs_reg(47 downto 36) & head_reorder_coeffs_reg(23 downto 12);
                butterfly0_b <= head_reorder_coeffs_reg(35 downto 24) & head_reorder_coeffs_reg(11 downto 0);

                butterfly0_zeta <= coeffs_doutb(35 downto 24) & coeffs_doutb(11 downto 0) when head_reorder_mux_shift_reg(0) = '1' else head_reorder_coeffs_reg(83 downto 72) & head_reorder_coeffs_reg(59 downto 48);
            -- kyber multiplication (part 2)
            when "011" =>
                butterfly0_a <= kyber_add_reduce(coeffs_doutb(11 downto 0), coeffs_doutb(35 downto 24)) & kyber_sub_reduce(x"000", coeffs_doutb(11 downto 0)) when head_reorder_mux_shift_reg(0) = '1' else kyber_add_reduce(head_reorder_coeffs_reg(59 downto 48), head_reorder_coeffs_reg(83 downto 72)) & kyber_sub_reduce(x"000", head_reorder_coeffs_reg(59 downto 48));
                butterfly0_b <= head_reorder_coeffs_reg(11 downto 0) & coeffs_doutb(35 downto 24) when head_reorder_mux_shift_reg(0) = '1' else head_reorder_coeffs_reg(11 downto 0) & head_reorder_coeffs_reg(83 downto 72);

                butterfly0_zeta <= head_reorder_coeffs_reg(35 downto 24) & zeta_shift_reg(0)(11 downto 0) when head_reorder_mux_shift_reg(0) = '1' else head_reorder_coeffs_reg(35 downto 24) & zeta_shift_reg(0)(23 downto 12);
            -- dilithium multiplication
            when others =>
                butterfly0_a <= head_reorder_coeffs_reg(47 downto 24); -- does not matter
                butterfly0_b <= head_reorder_coeffs_reg(23 downto 0);

                butterfly0_zeta <= coeffs_doutb(23 downto 0) when head_reorder_mux_shift_reg(0) = '1' else head_reorder_coeffs_reg(71 downto 48);
        end case;
    end process;

    butterfly1: entity work.butterfly
    port map (
        clk => clk,
        rst => rst,

        mode => read_mode,

        A => butterfly1_a,
        B => butterfly1_b,

        zeta => butterfly1_zeta,

        C => butterfly1_c,
        D => butterfly1_d,

        inplace_coeffs => butterfly1_inplace_coeffs,
        inplace_op => inplace_op,
        inplace_next => open, -- same as butterfly0 is inplace_next

        vld_in => butterfly_vld_in,
        vld_out => open -- same as butterfly0 is vld
    );

    butterfly1_inplace_coeffs <= inplace_coeffs(47 downto 24) when inplace_mux = '0' else inplace_coeffs(95 downto 72);

    proc_butterfly1: process(all) is
    begin
        case read_mode is
            -- NTT
            when "000" | "100" =>
                butterfly1_a <= head_reorder_coeffs_reg(47 downto 24);
                butterfly1_b <= coeffs_doutb(47 downto 24) when head_reorder_mux_shift_reg(0) = '1' else head_reorder_coeffs_reg(95 downto 72);

                butterfly1_zeta <= zeta_shift_reg(0)(47 downto 24);
            -- kyber INTT
            when "001" =>
                butterfly1_a <= head_reorder_coeffs_reg(47 downto 24);
                butterfly1_b <= coeffs_doutb(47 downto 24) when head_reorder_mux_shift_reg(0) = '1' else head_reorder_coeffs_reg(95 downto 72);

                butterfly1_zeta <= zeta_shift_reg(0)(11 downto 0) & zeta_shift_reg(0)(23 downto 12);
            -- dilithium INTT
            when "101" =>
                butterfly1_a <= coeffs_doutb(47 downto 24) when head_reorder_mux_shift_reg(0) = '1' else head_reorder_coeffs_reg(95 downto 72);
                butterfly1_b <= head_reorder_coeffs_reg(47 downto 24);

                butterfly1_zeta <= sub_reduce(x"000000", zeta_shift_reg(0)(23 downto 0), '1');
            -- kyber multiplication (part 1)
            when "010" =>
                butterfly1_a <= coeffs_doutb(35 downto 24) & coeffs_doutb(11 downto 0) when head_reorder_mux_shift_reg(0) = '1' else head_reorder_coeffs_reg(83 downto 72) & head_reorder_coeffs_reg(59 downto 48);
                butterfly1_b <= coeffs_doutb(47 downto 36) & coeffs_doutb(23 downto 12) when head_reorder_mux_shift_reg(0) = '1' else head_reorder_coeffs_reg(95 downto 84) & head_reorder_coeffs_reg(71 downto 60);

                butterfly1_zeta <= head_reorder_coeffs_reg(47 downto 36) & head_reorder_coeffs_reg(23 downto 12);
            -- kyber multiplication (part 2)
            when "011" =>
                butterfly1_a <= kyber_add_reduce(coeffs_doutb(23 downto 12), coeffs_doutb(47 downto 36)) & kyber_sub_reduce(x"000", coeffs_doutb(23 downto 12)) when head_reorder_mux_shift_reg(0) = '1' else kyber_add_reduce(head_reorder_coeffs_reg(71 downto 60), head_reorder_coeffs_reg(95 downto 84)) & kyber_sub_reduce(x"000", head_reorder_coeffs_reg(71 downto 60));
                butterfly1_b <= head_reorder_coeffs_reg(23 downto 12) & coeffs_doutb(47 downto 36) when head_reorder_mux_shift_reg(0) = '1' else head_reorder_coeffs_reg(23 downto 12) & head_reorder_coeffs_reg(95 downto 84);

                butterfly1_zeta <= head_reorder_coeffs_reg(47 downto 36) & kyber_sub_reduce(x"000", zeta_shift_reg(0)(11 downto 0)) when head_reorder_mux_shift_reg(0) = '1' else head_reorder_coeffs_reg(47 downto 36) & kyber_sub_reduce(x"000", zeta_shift_reg(0)(23 downto 12));
            -- dilithium multiplication
            when others =>
                butterfly1_a <= coeffs_doutb(23 downto 0) when head_reorder_mux_shift_reg(0) = '1' else head_reorder_coeffs_reg(71 downto 48); -- does not matter
                butterfly1_b <= coeffs_doutb(47 downto 24) when head_reorder_mux_shift_reg(0) = '1' else head_reorder_coeffs_reg(95 downto 72);

                butterfly1_zeta <= head_reorder_coeffs_reg(47 downto 24);
        end case;
    end process;

    -- delay enable and address signals for coeffs writing
    proc_coeffs: process(clk) is
    begin
        if rising_edge(clk) then
            coeffs_addra_reg <= get_address(write_iteration, std_logic_vector(write_counter));

            if rst = '1' then
                last_iteration_reg <= '0';
                coeffs_wea_reg <= '0';
            else
                last_iteration_reg <= write_iteration_last;
                coeffs_wea_reg <= butterfly_vld_out;
            end if;
        end if;
    end process;

    -- determine when butterfly should be active and store correct mode of operation
    proc_butterfly: process(clk) is
    begin
        if rising_edge(clk) then
            if rst = '1' then
                butterfly_vld_in <= '0';
            else
                butterfly_vld_in <= not idle_shift_reg(0);
            end if;

            if start = '1' then
                read_mode <= mode;
            end if;
        end if;
    end process;

    -- example for first iteration:
    --  - first cycle => coeffs_doutb = (0, 1, 2, 3, 4, 5, 6, 7) => head_reorder_coeffs_reg = (0, 1, 2, 3, 4, 5, 6, 7)
    --  - second cycle => coeffs_doutb = (128, 129, 130, 131, 132, 133, 134, 135) => head_reorder_coeffs_reg = (4, 5, 6, 7, 132, 133, 134, 135) => butterfly0_a = 1 & 0, butterfly0_b = 129 & 128, butterfly1_a = 3 & 2, butterfly1_b = 131 & 130
    --  - third cycle => coeffs_doutb = (8, 9, 10, 11, 12, 13, 14, 15) => head_reorder_coeffs_reg = (8, 9, 10, 11, 12, 13, 14, 15) => butterfly0_a = 5 & 4, butterfly0_b = 133 & 132, butterfly1_a = 7 & 6, butterfly1_b = 135 & 134
    proc_head_reorder: process(clk) is
    begin
        if rising_edge(clk) then
            if idle = '1' or read_iteration < 2 then
                head_reorder_mux_en <= '0';
            else
                head_reorder_mux_en <= '1';
            end if;

            if read_mode(1) = '0' and read_iteration = 0 then
                head_reorder_zero_iteration_shift_reg <= '1' & head_reorder_zero_iteration_shift_reg(head_reorder_zero_iteration_shift_reg'left downto 1);
            else
                head_reorder_zero_iteration_shift_reg <= '0' & head_reorder_zero_iteration_shift_reg(head_reorder_zero_iteration_shift_reg'left downto 1);
            end if;

            head_reorder_mux_shift_reg <= (not head_reorder_mux_shift_reg(head_reorder_mux_shift_reg'left) and head_reorder_mux_en) & head_reorder_mux_shift_reg(head_reorder_mux_shift_reg'left downto 1);

            if head_reorder_zero_iteration_shift_reg(0) = '1' then
                if read_mode(2) = '1' then
                    head_reorder_coeffs_reg <= coeffs_doutb(95 downto 72) & coeffs_doutb(47 downto 24) & coeffs_doutb(71 downto 48) & coeffs_doutb(23 downto 0);
                else
                    head_reorder_coeffs_reg <= coeffs_doutb(95 downto 84) & coeffs_doutb(47 downto 36) & coeffs_doutb(83 downto 72) & coeffs_doutb(35 downto 24) &
                        coeffs_doutb(71 downto 60) & coeffs_doutb(23 downto 12) & coeffs_doutb(59 downto 48) & coeffs_doutb(11 downto 0);
                end if;
            elsif head_reorder_mux_shift_reg(0) = '0' then
                head_reorder_coeffs_reg <= coeffs_doutb;
            else
                head_reorder_coeffs_reg <= coeffs_doutb(95 downto 48) & head_reorder_coeffs_reg(95 downto 48);
            end if;
        end if;
    end process;

    -- determine correct zeta_index on mode
    with read_mode select zeta_index <=
        zeta_index_no_mode + 1 when "000",
        95 - zeta_index_no_mode when "001",
        zeta_index_no_mode + 1 when "100",
        191 - zeta_index_no_mode when "101",
        zeta_index_no_mode + 64 when others;

    -- determine correct zeta to corresponding `read_iteration` and `read_counter`
    proc_zeta: process(clk) is
    begin
        if rising_edge(clk) then
            -- enable zeta index counter when zeta should be increased
            if (read_counter_last and read_iteration_last) = '1' then
                zeta_index_en <= '0';
            else
                case read_iteration is
                    when 2 => zeta_index_en <= read_counter(0);
                    when 3 => zeta_index_en <= and read_counter(1 downto 0);
                    when 4 => zeta_index_en <= and read_counter(2 downto 0);
                    when 5 => zeta_index_en <= and read_counter(3 downto 0);
                    when 6 => zeta_index_en <= and read_counter(4 downto 0);
                    when 7 => zeta_index_en <= and read_counter(5 downto 0);
                    when 8 => zeta_index_en <= read_counter(0);
                    when others => zeta_index_en <= '1';
                end case;
            end if;

            if idle_shift_reg(idle_shift_reg'left) = '1' then
                zeta_index_no_mode <= 0;
            elsif zeta_index_en = '1' then
                zeta_index_no_mode <= zeta_index_no_mode + 1;
            end if;

            if idle_shift_reg(idle_shift_reg'left) = '0' then
                if read_mode(2) = '0' then
                    if zeta_index < 64 then
                        zeta_shift_reg(zeta_shift_reg'left) <= KYBER_ZETAS(zeta_index) & KYBER_ZETAS(zeta_index) & KYBER_ZETAS(zeta_index) & KYBER_ZETAS(zeta_index);
                    else
                        zeta_shift_reg(zeta_shift_reg'left) <= KYBER_ZETAS2(zeta_index - 64) & KYBER_ZETAS(zeta_index) & KYBER_ZETAS2(zeta_index - 64) & KYBER_ZETAS(zeta_index);
                    end if;
                else
                    if zeta_index < 128 then
                        zeta_shift_reg(zeta_shift_reg'left) <= DILITHIUM_ZETAS(zeta_index) & DILITHIUM_ZETAS(zeta_index);
                    else
                        zeta_shift_reg(zeta_shift_reg'left) <= DILITHIUM_ZETAS2(zeta_index - 128) & DILITHIUM_ZETAS(zeta_index);
                    end if;
                end if;
            end if;

            zeta_shift_reg(zeta_shift_reg'left - 1 downto 0) <= zeta_shift_reg(zeta_shift_reg'left downto 1);
        end if;
    end process;

    -- example for first iteration:
    --  - first cycle => butterfly0_c = 1 & 0, butterfly0_d = 129 & 128, butterfly1_c = 3 & 2, butterfly1_d = 131 & 130 => tail_reorder_coeffs_reg = (0, 1, 2, 3, 128, 129, 130, 131)
    --  - second cycle => butterfly0_c = 5 & 4, butterfly0_d = 133 & 132, butterfly1_c = 7 & 6, butterfly1_d = 135 & 134 => tail_reorder_coeffs_reg = (128, 129, 130, 131, 132, 133, 134, 135), coeffs_dina = (0, 1, 2, 3, 4, 5, 6, 7)
    --  - third cycle => butterfly0_c = 9 & 8, butterfly0_d = 137 & 136, butterfly1_c = 11 & 10, butterfly1_d = 139 & 138 => tail_reorder_coeffs_reg = (8, 9, 10, 11, 136, 137, 138, 139), coeffs_dina = (128, 129, 130, 131, 132, 133, 134, 135)
    proc_tail_reorder: process(clk) is
    begin
        if rising_edge(clk) then
            if butterfly_vld_out = '0' or write_iteration < 2 then
                tail_reorder_mux <= '0';
            else
                tail_reorder_mux <= not tail_reorder_mux;
            end if;

            if write_mode(1) = '0' and write_iteration = 0 then
                if write_mode(2) = '1' then
                    tail_reorder_coeffs_reg <= butterfly1_d & butterfly1_c & butterfly0_d & butterfly0_c;
                else
                    tail_reorder_coeffs_reg <= butterfly1_d(23 downto 12) & butterfly0_d(23 downto 12) & butterfly1_c(23 downto 12) & butterfly0_c(23 downto 12) &
                        butterfly1_d(11 downto 0) & butterfly0_d(11 downto 0) & butterfly1_c(11 downto 0) & butterfly0_c(11 downto 0);
                end if;
            elsif tail_reorder_mux = '0' then
                tail_reorder_coeffs_reg <= butterfly1_d & butterfly0_d & butterfly1_c & butterfly0_c;
            else
                tail_reorder_coeffs_reg <= butterfly1_d & butterfly0_d & tail_reorder_coeffs_reg(95 downto 48);
            end if;
        end if;
    end process;

    with write_mode(2 downto 1) select write_counter_last <=
        and write_counter(4 downto 0) when "00",
        and write_counter when "11",
        and write_counter(5 downto 0) when others;

    with read_mode(2 downto 1) select read_counter_last <=
        and read_counter(4 downto 0) when "00",
        and read_counter when "11",
        and read_counter(5 downto 0) when others;

    write_iteration_target <= 7 when write_mode(2) = '1' else 6;
    read_iteration_target <= 7 when read_mode(2) = '1' else 6;

    write_iteration_last <= '1' when write_iteration_no_mode = write_iteration_target else write_mode(1);
    read_iteration_last <= '1' when read_iteration_no_mode = read_iteration_target else read_mode(1);

    -- determine correct iterations based on mode
    write_iteration <= write_iteration_target - write_iteration_no_mode when write_mode(1 downto 0) = "00" else
        9 when write_mode(2 downto 1) = "11" else
        8 when write_mode(2 downto 1) = "01" else
        write_iteration_no_mode;
    read_iteration <= read_iteration_target - read_iteration_no_mode when read_mode(1 downto 0) = "00" else
        9 when read_mode(2 downto 1) = "11" else
        8 when read_mode(2 downto 1) = "01" else
        read_iteration_no_mode;

    -- counters that are used to address coefficients memory
    proc_counter: process(clk) is
    begin
        if rising_edge(clk) then
            -- when there is valid output from butterfly unit it will write coefficients every cycle
            if butterfly_vld_out = '0' then
                write_counter <= (others => '0');
                write_iteration_no_mode <= 0;
            else
                if write_counter_last then
                    write_counter <= (others => '0');
                else
                    write_counter <= write_counter + 1;
                end if;

                if (write_counter_last and not write_iteration_last and not read_mode(1)) = '1' then
                    write_iteration_no_mode <= write_iteration_no_mode + 1;
                end if;
            end if;

            -- when component is not idle it will read coefficients every clock cycle
            if idle = '1' then
                read_counter <= (others => '0');
                read_iteration_no_mode <= 0;
            else
                if read_counter_last then
                    read_counter <= (others => '0');
                else
                    read_counter <= read_counter + 1;
                end if;

                if (read_counter_last and not read_iteration_last and not write_mode(1)) = '1' then
                    read_iteration_no_mode <= read_iteration_no_mode + 1;
                end if;
            end if;

            -- store correctly mode until all coefficients are written
            if write_counter = 0 and write_iteration_no_mode = 0 then
                write_mode <= read_mode;
            end if;
        end if;
    end process;

    process(clk) is
    begin
        if rising_edge(clk) then
            vld_reg <= write_counter_last and write_iteration_last;

            if rst = '1' then
                idle <= '1';
                idle_shift_reg <= (others => '1');
            else
                if start = '1' then
                    idle <= '0';
                elsif (read_counter_last and read_iteration_last) = '1' then
                    idle <= '1';
                end if;

                idle_shift_reg <= idle & idle_shift_reg(idle_shift_reg'left downto 1);
            end if;
        end if;
    end process;
end;
