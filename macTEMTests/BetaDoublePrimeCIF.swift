//
//  BetaDoublePrimeCIF.swift
//  Role: the beta'' (Mg5Si6) CIF text the Diffraction tests load, as tools/parity/crystal-structures/make_beta_double_prime.py writes it.
//

nonisolated enum BetaDoublePrimeCIF {
    /// The CIF `make_beta_double_prime.py` writes (cell and Table 3 set 3 of Andersen et al., Acta Mater. 46, 3283).
    static let text = """
        data_beta_double_prime_Mg5Si6
        _chemical_name_mineral            'beta-double-prime'
        _chemical_formula_sum             'Mg10 Si12'
        _chemical_formula_structural      'Mg5 Si6'
        _publ_author_name                 'Andersen, S. J.'
        _journal_name_full                'Acta Materialia'
        _journal_volume                   46
        _journal_year                     1998
        _journal_page_first               3283
        _cell_length_a                    15.16
        _cell_length_b                    4.05
        _cell_length_c                    6.74
        _cell_angle_alpha                 90.0
        _cell_angle_beta                  105.3
        _cell_angle_gamma                 90.0
        _symmetry_space_group_name_H-M    'C 2/m'
        _symmetry_Int_Tables_number       12
        loop_
        _symmetry_equiv_pos_as_xyz
          'x,y,z'
          '-x,y,-z'
          '-x,-y,-z'
          'x,-y,z'
          '1/2+x,1/2+y,z'
          '1/2-x,1/2+y,-z'
          '1/2-x,1/2-y,-z'
          '1/2+x,1/2-y,z'
        loop_
        _atom_site_label
        _atom_site_type_symbol
        _atom_site_fract_x
        _atom_site_fract_y
        _atom_site_fract_z
        _atom_site_occupancy
        _atom_site_B_iso_or_equiv
          Mg1   Mg    0.0000   0.0000   0.0000  1.0  0.5
          Mg2   Mg    0.3459   0.0000   0.0890  1.0  1.0
          Mg3   Mg    0.4300   0.0000   0.6520  1.0  0.8
          Si1   Si    0.0565   0.0000   0.6490  1.0  1.1
          Si2   Si    0.1885   0.0000   0.2240  1.0  0.5
          Si3   Si    0.2171   0.0000   0.6170  1.0  2.5
        """
}
