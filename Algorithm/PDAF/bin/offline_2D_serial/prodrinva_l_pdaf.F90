!$Id: prodrinva_l_pdaf.F90 1369 2013-04-24 16:38:17Z lnerger $
!BOP
!
! !ROUTINE: prodRinvA_l_pdaf --- Compute product of inverse of R with some matrix
!
! !INTERFACE:
SUBROUTINE prodRinvA_l_pdaf(domain_p, step, dim_obs_l, rank, obs_l, A_l, C_l)

    ! !DESCRIPTION:
    ! User-supplied routine for PDAF.
    ! Used in the filters: LSEIK/LETKF/LESTKF
    !
    ! The routine is called during the analysis step
    ! on each local analysis domain. It has to
    ! compute the product of the inverse of the local
    ! observation error covariance matrix with
    ! the matrix of locally observed ensemble
    ! perturbations.
    ! Next to computing the product,  a localizing
    ! weighting (similar to covariance localization
    ! often used in EnKF) can be applied to matrix A.
    !
    ! Implementation for the 2D offline example
    ! without parallelization.
    !
    ! !REVISION HISTORY:
    ! 2013-02 - Lars Nerger - Initial code
    ! Later revisions - see svn log
    !
    ! !USES:
    USE mod_assimilation, &
        ONLY: local_range, locweight, srange, rms_obs, &
        obs_index_l, coords_obs, coords_l, &
        STATE_DIM, OBS_DIM, ENSEMBLE_NUMBER, ncid, varid, &
        XF_NC, HXF_NC, OBS_NC, XF_COORD_NC, OBS_COORD_NC, R_NC, H_NC, R_Local_l, coords_obs_l, &
        FILE_NAME, STATE_DIM_NAME, OBS_DIM_NAME, ENSEMBLE_NUMBER_NAME, &
        XF_NAME, HXF_NAME, H_NAME, OBS_NAME, XF_COORD_NAME, OBS_COORD_NAME, R_NAME, XA_NAME, XM_NAME

#if defined (_OPENMP)
  USE omp_lib, &
       ONLY: omp_get_thread_num
#endif

    IMPLICIT NONE

    ! !ARGUMENTS:
    INTEGER, INTENT(in) :: domain_p          ! Current local analysis domain
    INTEGER, INTENT(in) :: step              ! Current time step
    INTEGER, INTENT(in) :: dim_obs_l         ! Dimension of local observation vector
    INTEGER, INTENT(in) :: rank              ! Rank of initial covariance matrix
    REAL, INTENT(in)    :: obs_l(dim_obs_l)  ! Local vector of observations
    REAL, INTENT(inout) :: A_l(dim_obs_l, rank) ! Input matrix
    REAL, INTENT(out)   :: C_l(dim_obs_l, rank) ! Output matrix

    ! !CALLING SEQUENCE:
    ! Called by: PDAF_lseik_analysis    (as U_prodRinvA_l)
    ! Called by: PDAF_lestkf_analysis   (as U_prodRinvA_l)
    ! Called by: PDAF_letkf_analysis    (as U_prodRinvA_l)
    !EOP


    ! *** local variables ***
    INTEGER :: i, j          ! Index of observation component
    INTEGER :: verbose       ! Verbosity flag
    INTEGER :: verbose_w     ! Verbosity flag for weight computation
    INTEGER :: ilow, iup     ! Lower and upper bounds of observation domain
    INTEGER :: domain        ! Global domain index
    INTEGER, SAVE :: domain_save = -1  ! Save previous domain index
    REAL    :: ivariance_obs ! Inverse of variance of the observations
    INTEGER :: wtype         ! Type of weight function
    INTEGER :: rtype         ! Type of weight regulation
    REAL, ALLOCATABLE :: weight(:)     ! Localization weights
    REAL, ALLOCATABLE :: distance(:)   ! Localization distance
    REAL, ALLOCATABLE :: A_obs(:,:)    ! Array for a single row of A_l
    REAL    :: meanvar                 ! Mean variance in observation domain
    REAL    :: svarpovar               ! Mean state plus observation variance
    REAL    :: var_obs                 ! Variance of observation error
    INTEGER, SAVE :: mythread          ! Thread variable for OpenMP

!$OMP THREADPRIVATE(mythread, domain_save)


    ! *********************************
    ! *** Initialize distance array ***
    ! *********************************

    ! *** The array holds the distance of an observation
    ! *** from local analysis domain.

    allocate(distance(dim_obs_l))

    init_distance: DO i = 1, dim_obs_l
        ! distance between analysis point and current observation
        distance(i) = SQRT(REAL((coords_l(1) - coords_obs_l(1, i))**2 + &
            (coords_l(2) - coords_obs_l(2, i))**2))
    END DO init_distance


      ! **********************
      ! *** INITIALIZATION ***
      ! **********************

! For OpenMP parallelization, determine the thread index
#if defined (_OPENMP)
  mythread = omp_get_thread_num()
#else
  mythread = 0
#endif

    IF (domain_p <= domain_save .OR. domain_save < 0) THEN
        verbose = 1
		! In case of OpenMP, let only thread 0 write output to the screen
		IF (mythread>0) verbose = 0
    ELSE
        verbose = 0
    END IF
    domain_save = domain_p

    ! Screen output
    IF (verbose == 1) THEN
        WRITE (*, '(8x, a, f12.3)') &
            '--- Use global rms for observations of ', rms_obs
        WRITE (*, '(8x, a, 1x)') &
            '--- Domain localization'
        WRITE (*, '(12x, a, 1x, f12.2)') &
            '--- Local influence radius', local_range

        IF (locweight > 0) THEN
            WRITE (*, '(12x, a)') &
                '--- Use distance-dependent weight for observation errors'

            IF (locweight == 3) THEN
                write (*, '(12x, a)') &
                    '--- Use regulated weight with mean error variance'
            ELSE IF (locweight == 4) THEN
                write (*, '(12x, a)') &
                    '--- Use regulated weight with single-point error variance'
            END IF
        END IF
    ENDIF

    ! ********************************
    ! *** Initialize weight array. ***
    ! ********************************

    ! Allocate weight array
    ALLOCATE(weight(dim_obs_l))

    if (locweight == 0) THEN
        ! Uniform (unit) weighting
        wtype = 0
        rtype = 0
    else if (locweight == 1) THEN
        ! Exponential weighting
        wtype = 1
        rtype = 0
    ELSE IF (locweight == 2 .OR. locweight == 3 .OR. locweight == 4) THEN
        ! 5th-order polynomial (Gaspari&Cohn, 1999)
        wtype = 2

        IF (locweight < 3) THEN
            ! No regulated weight
            rtype = 0
        ELSE
            ! Use regulated weight
            rtype = 1
        END IF

    end if

    IF (locweight == 4) THEN
        ! Allocate array for single observation point
        ALLOCATE(A_obs(1, rank))
    END IF


    ! ********************
    ! *** Apply weight ***
    ! ********************

    DO j = 1, rank
        DO i = 1, dim_obs_l
            !IF(R_Local_l(i ,i) .NE. 4) THEN
            !    print*,"R_Local_l(i ,i)",i,R_Local_l(i ,i)
            !END IF
            !print*,"R_Local_l(i ,i)",i,R_Local_l(i ,i)
            ivariance_obs = 1.0 / R_Local_l(i ,i)
            var_obs = R_Local_l(i ,i)

            ! Control verbosity of PDAF_local_weight
            IF (verbose==1 .AND. i==1) THEN
                verbose_w = 1
            ELSE
                verbose_w = 0
            END IF

            IF (locweight /= 4) THEN
                ! All localizations except regulated weight based on variance at
                ! single observation point
                CALL PDAF_local_weight(wtype, rtype, local_range, srange, distance(i), &
                    dim_obs_l, rank, A_l, var_obs, weight(i), verbose_w)
            ELSE
                ! Regulated weight using variance at single observation point
                A_obs(1,:) = A_l(i,:)
                CALL PDAF_local_weight(wtype, rtype, local_range, srange, distance(i), &
                    1, rank, A_obs, var_obs, weight(i), verbose_w)
            END IF

            !print*,"weight(i)",i,weight(i)
            C_l(i, j) = ivariance_obs * weight(i) * A_l(i, j)
            !print*,"weight(i)",i,ivariance_obs,weight(i),A_l(i, j),C_l(i, j)
        END DO
    END DO


    ! *** Clean up ***

    DEALLOCATE(weight, distance)
    IF (locweight == 4) DEALLOCATE(A_obs)
  
END SUBROUTINE prodRinvA_l_pdaf
