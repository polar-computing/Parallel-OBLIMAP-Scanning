! File name: oblimap_mapping_module.f90
!
! Copyright (C) 2016 Thomas Reerink & Michael Kliphuis.
!
! This file is distributed under the terms of the
! GNU General Public License.
!
! This file is part of OBLIMAP 2.0
!
! OBLIMAP's scientific documentation and its first open source
! release (see the supplement) is published at:
! http://www.geosci-model-dev.net/3/13/2010/gmd-3-13-2010.html
!
! OBLIMAP is free software: you can redistribute it and/or modify
! it under the terms of the GNU General Public License as published by
! the Free Software Foundation, either version 3 of the License, or
! (at your option) any later version.
!
! OBLIMAP is distributed in the hope that it will be useful,
! but WITHOUT ANY WARRANTY; without even the implied warranty of
! MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
! GNU General Public License for more details.
!
! You should have received a copy of the GNU General Public License
! along with OBLIMAP. If not, see <http://www.gnu.org/licenses/>.
!
!
! OBLIMAP is maintained by:
!
! Thomas Reerink
! Institute for Marine and Atmospheric Research Utrecht (IMAU)
! Utrecht University
! Princetonplein 5
! 3584 CC Utrecht
! The Netherlands
!
! email: tjreerink@gmail.com
!

MODULE oblimap_mapping_module
  USE oblimap_configuration_module, ONLY: dp
  IMPLICIT NONE

  TYPE scanned_projection_data
    INTEGER                               :: maximum_contributions     ! Maximum number of contributing points (depends on the C%oblimap_allocate_factor)
    INTEGER                               :: total_mapped_points       ! Amount of affected/mapped/target grid points by the mapping
    INTEGER , DIMENSION(:  ), ALLOCATABLE :: row_mapped                ! Row index of the affected/mapped/target points
    INTEGER , DIMENSION(:  ), ALLOCATABLE :: column_mapped             ! Column index of the affected/mapped/target points
!   INTEGER , DIMENSION(:  ), ALLOCATABLE :: row_index_mapped          ! Row index of the affected/mapped/target points
!   INTEGER , DIMENSION(:  ), ALLOCATABLE :: column_index_mapped       ! Column index of the affected/mapped/target points
    INTEGER , DIMENSION(:  ), ALLOCATABLE :: total_contributions       ! Number of contributing points used to estimate the field value for the grid point
    INTEGER , DIMENSION(:,:), ALLOCATABLE :: row_index                 ! Row index of contributing point
    INTEGER , DIMENSION(:,:), ALLOCATABLE :: column_index              ! Column index of contributing point
!   INTEGER , DIMENSION(:,:), ALLOCATABLE :: row_index_contribution    ! Row index of contributing point
!   INTEGER , DIMENSION(:,:), ALLOCATABLE :: column_index_contribution ! Column index of contributing point
    REAL(dp), DIMENSION(:,:), ALLOCATABLE :: distance                  ! Distance of this nearest point relative to the IM point (m,n)
  END TYPE scanned_projection_data



CONTAINS

  SUBROUTINE mapping(scanned, N_row_input, N_column_input, N_row_mapped, N_column_mapped, mask_of_invalid_contributions, input_field, mapped_field, mapping_participation_mask)
    ! This routine contains the superfast mapping method.
    !   mapping = (inverse) oblique projection + interpolation
    ! It is suited for all OBLIMAP situations like for example:
    !  oblique projection + quadrant interpolation
    !  oblique projection + radius   interpolation
    !  oblique projection + nearest point assignment
    !  inverse oblique projection + quadrant interpolation
    !  inverse oblique projection + radius   interpolation
    !  inverse oblique projection + nearest point assignment
    USE oblimap_configuration_module, ONLY : dp, C
    USE oblimap_scan_contributions_module, ONLY: triplet
    IMPLICIT NONE

    ! Input variables:
    TYPE(scanned_projection_data),                                                                              INTENT(IN)            :: scanned                        ! A 'struct' containing all the scanned contributions
    INTEGER,                                                                                                    INTENT(IN)            :: N_row_input
    INTEGER,                                                                                                    INTENT(IN)            :: N_column_input
    INTEGER,                                                                                                    INTENT(IN)            :: N_row_mapped
    INTEGER,                                                                                                    INTENT(IN)            :: N_column_mapped
    LOGICAL,  DIMENSION(C%number_of_mapped_fields, N_row_input,  N_column_input , C%number_of_vertical_layers), INTENT(IN)            :: mask_of_invalid_contributions  ! For each field and for each layer a mask represents the invalid contributions (like e.g. missing values)
    REAL(dp), DIMENSION(C%number_of_mapped_fields, N_row_input,  N_column_input , C%number_of_vertical_layers), INTENT(IN)            :: input_field

    ! Output variables:
    REAL(dp), DIMENSION(C%number_of_mapped_fields, N_row_mapped, N_column_mapped, C%number_of_vertical_layers), INTENT(OUT)           :: mapped_field
    INTEGER,  DIMENSION(                           N_row_mapped, N_column_mapped                             ), INTENT(OUT), OPTIONAL :: mapping_participation_mask

    ! Local variables:
    INTEGER                                                                                                                           :: p                              ! Counter which counts over the affected/mapped/target points
    INTEGER                                                                                                                           :: q                              ! Counter over the contributing points at each target point
    REAL(dp), DIMENSION(C%number_of_mapped_fields)                                                                                    :: numerator                      ! The   numerator in equation (2.19) in Reerink et al. (2010), the Shepard formula
    REAL(dp), DIMENSION(C%number_of_mapped_fields)                                                                                    :: denumerator                    ! The denumerator in equation (2.19) in Reerink et al. (2010), the Shepard formula
    INTEGER                                                                                                                           :: field_counter                  ! The counter in the loop over the field numbers
    INTEGER                                                                                                                           :: layer_counter                  ! The counter over the vertical layers
    TYPE(triplet)                                                                                                                     :: nearest_contribution           ! The nearest projected contribution near the target point
    LOGICAL                                                                                                                , SAVE     :: message_once = .TRUE.          ! Give this message only once, not for each repeated call of this subroutine

    ! For points for which no contribution are found at all, the fields are set to zero:
    mapped_field = 0._dp

    IF(PRESENT(mapping_participation_mask)) mapping_participation_mask = 0

    ! The layer loop is choosen as the outermost loop for performance reason: because by far the majority of the applications do not use more
    ! then one layer. In case of more vertical layers this implementation does not give the best performance (however differences will be small).
    DO layer_counter = 1, C%number_of_vertical_layers
     ! See equation (2.17) and equation (2.19) in Reerink et al. (2010), both cases are treated with the same code:
     DO p = 1, scanned%total_mapped_points
       nearest_contribution%row_index    = -1                ! Initialize at an inappropriate value
       nearest_contribution%column_index = -1                ! Initialize at an inappropriate value
       nearest_contribution%distance     = C%large_distance  ! Initialize at a large value
       numerator   = 0._dp
       denumerator = 0._dp

       DO q = 1, scanned%total_contributions(p)
         ! Select the nearest projected contribution:
         IF(scanned%distance(p,q) < nearest_contribution%distance) THEN
          nearest_contribution%row_index    = scanned%row_index(p,q)
          nearest_contribution%column_index = scanned%column_index(p,q)
          nearest_contribution%distance     = scanned%distance(p,q)
         END IF

         ! Contributions which have no invalid value mask will be taken into account:
         DO field_counter = 1, C%number_of_mapped_fields
          IF(.NOT. mask_of_invalid_contributions(field_counter,scanned%row_index(p,q),scanned%column_index(p,q),layer_counter)) THEN
           ! See numerator in equation (2.17) and equation (2.19) in Reerink et al. (2010):
           numerator(field_counter)   = numerator(field_counter) + input_field(field_counter,scanned%row_index(p,q),scanned%column_index(p,q),layer_counter) / (scanned%distance(p,q)**C%shepard_exponent)
           ! See denumerator in equation (2.17) and equation (2.19) in Reerink et al. (2010):
           denumerator(field_counter) = denumerator(field_counter) + (1._dp / (scanned%distance(p,q)**C%shepard_exponent))
          END IF
         END DO
       END DO

       IF(scanned%total_contributions(p) == 0) THEN
        ! If there are no contributions found set the field value to an invalid value (this should actually not occur, because such points are never written to the scanned file):
        mapped_field(:,scanned%row_mapped(p),scanned%column_mapped(p),layer_counter) = C%invalid_input_value(:)
       ELSE IF(C%nearest_point_assignment) THEN
        ! Nearest point assignment instead of interpolation of various neighbour points:
        DO field_counter = 1, C%number_of_mapped_fields
         IF(mask_of_invalid_contributions(field_counter,nearest_contribution%row_index,nearest_contribution%column_index,layer_counter)) THEN
          mapped_field(field_counter,scanned%row_mapped(p),scanned%column_mapped(p),layer_counter) = C%invalid_input_value(field_counter)
         ELSE
          mapped_field(field_counter,scanned%row_mapped(p),scanned%column_mapped(p),layer_counter) = input_field(field_counter,nearest_contribution%row_index,nearest_contribution%column_index,layer_counter)
         END IF
        END DO
       ELSE
        DO field_counter = 1, C%number_of_mapped_fields
         IF((C%invalid_value_mask_criterion(field_counter) == 1) .AND. mask_of_invalid_contributions(field_counter,nearest_contribution%row_index,nearest_contribution%column_index,layer_counter)) THEN
          ! NOTE: In case the nearest contributing point is invalid but all other contributing points are valid, then the mapped point will be taken invalid. And vice versa.
          mapped_field(field_counter,scanned%row_mapped(p),scanned%column_mapped(p),layer_counter) = C%invalid_input_value(field_counter)
         ELSE
          mapped_field(field_counter,scanned%row_mapped(p),scanned%column_mapped(p),layer_counter) = numerator(field_counter) / denumerator(field_counter)
         !mapped_field(field_counter,scanned%row_mapped(p),scanned%column_mapped(p),layer_counter) = numerator(field_counter,layer_counter) / denumerator(field_counter,layer_counter)    !!! In case the layer loop is brought inside
         END IF
        END DO
       END IF
       ! The scanned file only contains lines for participating points, so only points which do not occur in the scanned file will keep a zero mapping_participation_mask:
       IF(PRESENT(mapping_participation_mask)) mapping_participation_mask(scanned%row_mapped(p),scanned%column_mapped(p)) = 1
     END DO
    END DO

    IF(message_once .AND. C%oblimap_message_level > 0) THEN
     IF(PRESENT(mapping_participation_mask)) THEN
      WRITE(UNIT=*, FMT='(3(A, I10), A)') ' Number of mapped points is:', scanned%total_mapped_points, ', maximum amount of contributions for one mapped point = ', scanned%maximum_contributions, '. No contributions found for ', COUNT(mapping_participation_mask == 0), ' points.'
     ELSE
      WRITE(UNIT=*, FMT='(2(A, I10)   )') ' Number of mapped points is:', scanned%total_mapped_points, ', maximum amount of contributions for one mapped point = ', scanned%maximum_contributions
     END IF
     message_once = .FALSE.
    END IF
  END SUBROUTINE mapping



  SUBROUTINE reading_the_scanned_projection_data(scanned_filename, scanned)
    ! This routine reads the scanned projection data into a struct. The struct is allocated here.
    ! This struct is used in the fast mapping routine.
    USE oblimap_configuration_module, ONLY : C
    IMPLICIT NONE

    ! Input variables:
    CHARACTER(LEN=*)             , INTENT(IN)  :: scanned_filename      ! The name of the file which contains the scanned projection data

    ! Output variables:
    TYPE(scanned_projection_data), INTENT(OUT) :: scanned               ! A 'struct' containing all the scanned contributions

    ! Local variables:
    LOGICAL                                    :: file_exists
    INTEGER                                    :: passing_header_line   ! Counter which walks over the header lines
    CHARACTER(256)                             :: end_of_line           ! A variable with which the end of line can be read
    LOGICAL                                    :: gcm_to_im_direction   ! This logical is true if the mapping direction is gcm to im, and false if it is im to gcm
    INTEGER                                    :: status                ! Variable for checking the allocation status
    INTEGER                                    :: p                     ! Counter which counts over the affected/mapped/target points
    INTEGER                                    :: q                     ! Counter over the contributing points at each target point

    ! Check file existence:
    INQUIRE(EXIST = file_exists, FILE = scanned_filename)
    IF(.NOT. file_exists) THEN
     WRITE(UNIT=*,FMT='(/4A/, 2A/)') C%OBLIMAP_ERROR, ' The file "', TRIM(scanned_filename), '" does not exist.', &
                                     '                This implies you have to set  scanning_mode_config = .TRUE.  in the config file: ', C%config_filename
     STOP
    END IF

    ! Opening the scanned file:
    OPEN(UNIT=118, FILE=TRIM(scanned_filename))

    gcm_to_im_direction = .TRUE.

    ! Ignoring the header while reading the header (the case numbers just refer to the line numbers in the header file):
    DO passing_header_line = 1, 55
     IF(C%suppress_check_on_scan_parameters) THEN
      READ(UNIT=118, FMT='(A)') end_of_line
     ELSE
      SELECT CASE(passing_header_line)
      CASE(2)
       ! Detect the mappping direction:
       READ(UNIT=118, FMT='(A)') end_of_line
       IF(TRIM(end_of_line) == '#  i  j  N  N(m  n  distance)') gcm_to_im_direction = .FALSE.
      CASE(14)
       IF(gcm_to_im_direction) THEN
        CALL read_and_compare_header_line_with_string( 118, C%gcm_input_filename                              , 'gcm_input_filename_config')
       ELSE
        CALL read_and_compare_header_line_with_string( 118, C%im_input_filename                               , 'im_input_filename_config')
       END IF
      CASE(16)
       CALL read_and_compare_header_line_with_integer(118, C%NLON                                             , 'NLON_config')
      CASE(17)
       CALL read_and_compare_header_line_with_integer(118, C%NLAT                                             , 'NLAT_config')
      CASE(18)
       CALL read_and_compare_header_line_with_integer(118, C%NX                                               , 'NX_config')
      CASE(19)
       CALL read_and_compare_header_line_with_integer(118, C%NY                                               , 'NY_config')
      CASE(20)
       CALL read_and_compare_header_line_with_real(   118, C%dx                                               , 'dx_config')
      CASE(21)
       CALL read_and_compare_header_line_with_real(   118, C%dy                                               , 'dy_config')
      CASE(22)
       IF(C%choice_projection_method == 'rotation_projection') THEN
        CALL read_and_compare_header_line_with_real(  118, C%shift_x_coordinate_rotation_projection           , 'shift_x_coordinate_rotation_projection_config')
       ELSE
        CALL read_and_compare_header_line_with_real(  118, C%radians_to_degrees * C%lambda_M                  , 'lambda_M_config')
       END IF
      CASE(23)
       IF(C%choice_projection_method == 'rotation_projection') THEN
        CALL read_and_compare_header_line_with_real(  118, C%shift_y_coordinate_rotation_projection           , 'shift_y_coordinate_rotation_projection_config')
       ELSE
        CALL read_and_compare_header_line_with_real(  118, C%radians_to_degrees * C%phi_M                     , 'phi_M_config')
       END IF
      CASE(24)
       IF(C%choice_projection_method == 'rotation_projection') THEN
        READ(UNIT=118, FMT='(A)') end_of_line
        ELSE
        IF(C%level_of_automatic_oblimap_scanning < 4) THEN
         CALL read_and_compare_header_line_with_real( 118, C%radians_to_degrees * C%alpha_stereographic       , 'alpha_stereographic_config')
        ELSE
         ! No check because the automatic oblimap scanning has overruled the config value during the scan.
         READ(UNIT=118, FMT='(A)') end_of_line
        END IF
       END IF
      CASE(25)
       SELECT CASE(C%choice_projection_method)
       CASE('rotation_projection')
       CALL read_and_compare_header_line_with_real(   118, C%radians_to_degrees * C%theta_rotation_projection, 'theta_rotation_projection_config')
       CASE('oblique_stereographic_projection','oblique_stereographic_projection_snyder','oblique_lambert_equal-area_projection_snyder')
        CALL read_and_compare_header_line_with_real(  118, C%earth_radius                                     , 'earth_radius_config')
       CASE('oblique_stereographic_projection_ellipsoid_snyder','oblique_lambert_equal-area_projection_ellipsoid_snyder')
        CALL read_and_compare_header_line_with_real(  118, C%a                                                , 'ellipsoid_semi_major_axis_config')
       END SELECT
      CASE(26)
       SELECT CASE(C%choice_projection_method)
       CASE('rotation_projection','oblique_stereographic_projection','oblique_stereographic_projection_snyder','oblique_lambert_equal-area_projection_snyder')
        READ(UNIT=118, FMT='(A)') end_of_line
       CASE('oblique_stereographic_projection_ellipsoid_snyder','oblique_lambert_equal-area_projection_ellipsoid_snyder')
        CALL read_and_compare_header_line_with_real(  118, C%e                                                , 'ellipsoid_excentricity_config')
       END SELECT
      CASE(27)
       CALL read_and_compare_header_line_with_string( 118, C%choice_projection_method                         , 'choice_projection_method_config')
      CASE(29)
       CALL read_and_compare_header_line_with_logical(118, C%enable_shift_im_grid                             , 'enable_shift_im_grid_config')
      CASE(30)
       CALL read_and_compare_header_line_with_real(   118, C%shift_x_coordinate_im_grid                       , 'shift_x_coordinate_im_grid_config')
      CASE(31)
       CALL read_and_compare_header_line_with_real(   118, C%shift_y_coordinate_im_grid                       , 'shift_y_coordinate_im_grid_config')
      CASE(32)
       CALL read_and_compare_header_line_with_real(   118, C%alternative_lambda_for_center_im_grid            , 'alternative_lambda_for_center_im_grid_config')
      CASE(33)
       CALL read_and_compare_header_line_with_real(   118, C%alternative_phi_for_center_im_grid               , 'alternative_phi_for_center_im_grid_config')
      CASE(35)
       CALL read_and_compare_header_line_with_real(   118, C%unit_conversion_x_ax                             , 'unit_conversion_x_ax_config')
      CASE(36)
       CALL read_and_compare_header_line_with_real(   118, C%unit_conversion_y_ax                             , 'unit_conversion_y_ax_config')
      CASE(37)
       CALL read_and_compare_header_line_with_logical(118, C%use_prefabricated_im_grid_coordinates            , 'use_prefabricated_im_grid_coordinates_config')
      CASE(38)
       IF(C%use_prefabricated_im_grid_coordinates) THEN
        CALL read_and_compare_header_line_with_string( 118, C%prefabricated_im_grid_filename                  , 'prefabricated_im_grid_filename_config')
       ELSE
        READ(UNIT=118, FMT='(A)') end_of_line
       END IF
      CASE(40)
       CALL read_and_compare_header_line_with_integer(118, C%level_of_automatic_oblimap_scanning              , 'level_of_automatic_oblimap_scanning_config')
      CASE(41)
       IF(C%level_of_automatic_oblimap_scanning < 1) THEN
        CALL read_and_compare_header_line_with_logical(118, C%data_set_is_cyclic_in_longitude                 , 'data_set_is_cyclic_in_longitude_config')
       ELSE
        ! No check because the automatic oblimap scanning has overruled the config value during the scan.
        READ(UNIT=118, FMT='(A)') end_of_line
       END IF
      CASE(42)
       IF(C%level_of_automatic_oblimap_scanning < 2) THEN
        CALL read_and_compare_header_line_with_logical(118, C%choice_quadrant_method                          , 'choice_quadrant_method_config')
       ELSE
        ! No check because the automatic oblimap scanning has overruled the config value during the scan.
        READ(UNIT=118, FMT='(A)') end_of_line
       END IF
      CASE(43)
       IF(C%choice_quadrant_method .OR. C%level_of_automatic_oblimap_scanning < 3) THEN
        ! No check because quadrant method is used or the automatic oblimap scanning has overruled the config value during the scan.
        READ(UNIT=118, FMT='(A)') end_of_line
       ELSE
        CALL read_and_compare_header_line_with_real(  118, C%R_search_interpolation                           , 'R_search_interpolation_config')
       END IF
      CASE(44)
       CALL read_and_compare_header_line_with_integer(118, C%scan_search_block_size                           , 'scan_search_block_size_config')
      CASE(45)
       CALL read_and_compare_header_line_with_integer(118, C%scan_search_block_size_step                      , 'scan_search_block_size_step_config')
      CASE(47)
       CALL read_and_compare_header_line_with_logical(118, C%vincenty_method_for_ellipsoid                    , 'vincenty_method_for_ellipsoid_config')
      CASE DEFAULT
       READ(UNIT=118, FMT='(A)') end_of_line
      END SELECT
     END IF
    END DO

    ! Reading the total number of mapped points. Each line in the file contains the necessary information of all the
    ! contributing points for one target grid point. The number of mapped (or target) points equals the number of lines
    READ(UNIT=118, FMT='(I20)') scanned%maximum_contributions
    READ(UNIT=118, FMT='(I20)') scanned%total_mapped_points
    READ(UNIT=118, FMT='(A  )') end_of_line
   !WRITE(UNIT=*, FMT='(2(A, I12))') ' Number of mapped points is: ', scanned%total_mapped_points, ', maximum amount of contributions for one mapped point = ', scanned%maximum_contributions

    ALLOCATE(scanned%row_mapped         (scanned%total_mapped_points                              ), &
             scanned%column_mapped      (scanned%total_mapped_points                              ), &
             scanned%total_contributions(scanned%total_mapped_points                              ), &
             scanned%row_index          (scanned%total_mapped_points,scanned%maximum_contributions), &
             scanned%column_index       (scanned%total_mapped_points,scanned%maximum_contributions), &
             scanned%distance           (scanned%total_mapped_points,scanned%maximum_contributions), &
             STAT=status)
    IF(status /= 0) THEN
     WRITE(UNIT=*, FMT='(/2A/)') C%OBLIMAP_ERROR, ' message from: reading_the_scanned_projection_data(): Could not allocate enough memory for the scanned struct.'
     STOP
    END IF

    ! See equation (2.17) and equation (2.19) in Reerink et al. (2010), both cases are treated with the same code:
    DO p = 1, scanned%total_mapped_points
     READ(UNIT=118, FMT='(3I6)', ADVANCE='NO') scanned%row_mapped(p), scanned%column_mapped(p), scanned%total_contributions(p)

     DO q = 1, scanned%total_contributions(p)
      READ(UNIT=118, FMT='(2I6,E23.15)', ADVANCE='NO') scanned%row_index(p,q), scanned%column_index(p,q), scanned%distance(p,q)
     END DO

     READ(UNIT=118, FMT='(A)') end_of_line
    END DO

    ! Closing the scanned file:
    CLOSE(UNIT=118)
  END SUBROUTINE reading_the_scanned_projection_data



  SUBROUTINE read_and_compare_header_line_with_integer(unit_number, compared_config_variable, name_compared_config_variable)
    USE oblimap_configuration_module, ONLY : C
    IMPLICIT NONE

    ! Input variables:
    INTEGER            :: unit_number
    INTEGER            :: compared_config_variable       ! This variable contains the variable identical to the one which is read from the config file
    CHARACTER(LEN=*)   :: name_compared_config_variable  ! To generate an adequate message the name of the config variable is required, which is available here

    ! Local variables:
    CHARACTER(41)      :: description                    ! The first part of the header line will be read into this variable.
    INTEGER            :: compare_integer                ! This variable contains the variable identical to the one which is read from the scanned file

    READ(UNIT=unit_number, FMT='(A63, I10)') description, compare_integer
    IF(compare_integer /= compared_config_variable) THEN
     WRITE(UNIT=*, FMT='(/4A         )') TRIM(C%OBLIMAP_WARNING), ' ', name_compared_config_variable, ' should be the same in the scanned file and in the config file.'
     WRITE(UNIT=*, FMT='( 3A, I9, 2A )') '                  ', name_compared_config_variable, ' = ', compare_integer, ' in the scanned file: ', TRIM(C%scanned_projection_data_filename)
     WRITE(UNIT=*, FMT='( 3A, I9, 2A/)') '            while ', name_compared_config_variable, ' = ', compared_config_variable, ' in the config  file: ', TRIM(C%config_filename)
    END IF
  END SUBROUTINE read_and_compare_header_line_with_integer



  SUBROUTINE read_and_compare_header_line_with_real(unit_number, compared_config_variable, name_compared_config_variable)
    USE oblimap_configuration_module, ONLY : C, dp
    IMPLICIT NONE

    ! Input variables:
    INTEGER            :: unit_number
    REAL(dp)           :: compared_config_variable       ! This variable contains the variable identical to the one which is read from the config file
    CHARACTER(LEN=*)   :: name_compared_config_variable  ! To generate an adequate message the name of the config variable is required, which is available here

    ! Local variables:
    CHARACTER(41)      :: description                    ! The first part of the header line will be read into this variable.
    REAL(dp)           :: compare_real                   ! This variable contains the variable identical to the one which is read from the scanned file

    READ(UNIT=unit_number, FMT='(A63, E24.16)') description, compare_real
    IF(compare_real - compared_config_variable > 1.0E-14) THEN
     WRITE(UNIT=*, FMT='(/4A             )') TRIM(C%OBLIMAP_WARNING), ' ', name_compared_config_variable, ' should be the same in the scanned file and in the config file.'
     WRITE(UNIT=*, FMT='( 3A, F26.16, 2A )') '                  ', name_compared_config_variable, ' = ', compare_real, ' in the scanned file: ', TRIM(C%scanned_projection_data_filename)
     WRITE(UNIT=*, FMT='( 3A, F26.16, 2A/)') '            while ', name_compared_config_variable, ' = ', compared_config_variable, ' in the config  file: ', TRIM(C%config_filename)
    END IF
  END SUBROUTINE read_and_compare_header_line_with_real



  SUBROUTINE read_and_compare_header_line_with_string(unit_number, compared_config_variable, name_compared_config_variable)
    USE oblimap_configuration_module, ONLY : C
    IMPLICIT NONE

    ! Input variables:
    INTEGER            :: unit_number
    CHARACTER(LEN=*)   :: compared_config_variable       ! This variable contains the variable identical to the one which is read from the config file
    CHARACTER(LEN=*)   :: name_compared_config_variable  ! To generate an adequate message the name of the config variable is required, which is available here

    ! Local variables:
    CHARACTER(41)      :: description                    ! The first part of the header line will be read into this variable.
    CHARACTER(256)     :: compare_string                 ! This variable contains the variable identical to the one which is read from the scanned file

    READ(UNIT=unit_number, FMT='(A63, A)') description, compare_string
    IF(compare_string /= compared_config_variable) THEN
     WRITE(UNIT=*, FMT='(/4A        )') TRIM(C%OBLIMAP_WARNING), ' ', name_compared_config_variable, ' should be the same in the scanned file and in the config file.'
     WRITE(UNIT=*, FMT='( 3A, A, 2A )') '                  ', name_compared_config_variable, ' = ', TRIM(compare_string), ' in the scanned file: ', TRIM(C%scanned_projection_data_filename)
     WRITE(UNIT=*, FMT='( 3A, A, 2A/)') '            while ', name_compared_config_variable, ' = ', TRIM(compared_config_variable), ' in the config  file: ', TRIM(C%config_filename)
    END IF
  END SUBROUTINE read_and_compare_header_line_with_string



  SUBROUTINE read_and_compare_header_line_with_logical(unit_number, compared_config_variable, name_compared_config_variable)
    USE oblimap_configuration_module, ONLY : C
    IMPLICIT NONE

    ! Input variables:
    INTEGER            :: unit_number
    LOGICAL            :: compared_config_variable       ! This variable contains the variable identical to the one which is read from the config file
    CHARACTER(LEN=*)   :: name_compared_config_variable  ! To generate an adequate message the name of the config variable is required, which is available here

    ! Local variables:
    CHARACTER(41)      :: description                    ! The first part of the header line will be read into this variable.
    LOGICAL            :: compare_logical                ! This variable contains the variable identical to the one which is read from the scanned file

    READ(UNIT=unit_number, FMT='(A63, L)') description, compare_logical
    IF(compare_logical .NEQV. compared_config_variable) THEN
     WRITE(UNIT=*, FMT='(/4A        )') TRIM(C%OBLIMAP_WARNING), ' ', name_compared_config_variable, ' should be the same in the scanned file and in the config file.'
     WRITE(UNIT=*, FMT='( 3A, L, 2A )') '                  ', name_compared_config_variable, ' = ', compare_logical, ' in the scanned file: ', TRIM(C%scanned_projection_data_filename)
     WRITE(UNIT=*, FMT='( 3A, L, 2A/)') '            while ', name_compared_config_variable, ' = ', compared_config_variable, ' in the config  file: ', TRIM(C%config_filename)
    END IF
  END SUBROUTINE read_and_compare_header_line_with_logical



  SUBROUTINE finalize_reading_the_scanned_projection_data(scanned)
    IMPLICIT NONE

    ! Input variables:
    TYPE(scanned_projection_data), INTENT(INOUT) :: scanned   ! A 'struct' containing all the scanned contributions

    DEALLOCATE(scanned%row_mapped         )
    DEALLOCATE(scanned%column_mapped      )
    DEALLOCATE(scanned%total_contributions)
    DEALLOCATE(scanned%row_index          )
    DEALLOCATE(scanned%column_index       )
    DEALLOCATE(scanned%distance           )
  END SUBROUTINE finalize_reading_the_scanned_projection_data

END MODULE oblimap_mapping_module