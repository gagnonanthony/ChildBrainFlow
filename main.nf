#!/usr/bin/env nextflow

nextflow.enable.dsl=2

params.help = false

// ** Importing modules and processes ** //
include {   fetch_id;
            get_data_freesurfer;
            get_data_tracking;
            get_data_tracking_infant;
            get_data_connectomics;
            get_data_connectomics_infant;
            get_data_template } from "./modules/io.nf"
include {   DWI;
            ANAT } from "./modules/tracking/workflows/preprocessing.nf"
include {   DTI } from "./modules/tracking/workflows/DTI.nf"
include {   SH } from "./modules/tracking/workflows/SH.nf"
include {   REGISTRATION } from "./modules/tracking/workflows/registration.nf"
include {   FODF } from "./modules/tracking/workflows/FODF.nf"
include {   TRACKING } from "./modules/tracking/workflows/tracking.nf"
include {   CONNECTOMICS } from "./modules/connectomics/workflows/connectomics.nf"
include {   POPULATION_TEMPLATE } from "./modules/template/workflows/pop_template.nf"
include {   FREESURFERFLOW } from "./modules/freesurfer/workflows/freesurferflow.nf"

workflow {
    if (params.help) { display_usage() }
    else {
        display_run_info()

        // ** Checking compatibility between profiles. ** //
        if ( params.infant_config && params.run_freesurfer ) {
            error "Profiles infant_config and freesurfer are not compatible since infant_freesurfer is not implemented."
        }

        if ( params.template_config ) {
            data = get_data_template()

            POPULATION_TEMPLATE(data.anat,
                                data.dwi,
                                data.fa,
                                data.anat_ref,
                                data.fa_ref)
        }

        if ( params.run_freesurfer ) {
            data = get_data_freesurfer()

            FREESURFERFLOW(data.anat)
        }

        if ( params.run_tracking ) {
            if ( params.infant_config ) {
                data = get_data_tracking_infant()
            } else {
                data = get_data_tracking()
            }

            // ** Merging mask and anat if -profile infant. ** //
            if ( params.infant_config ) {
                anat_channel = data.anat
                                .combine(data.wm_mask, by: 0)
            } 
            else {
                anat_channel = data.anat
            }
            // ** Anatomical preprocessing ** //
            ANAT(anat_channel)

            // ** DWI preprocessing ** //
            DWI(data.dwi,
                data.rev)
            
            // ** DTI modelling ** //
            DTI(DWI.out.dwi_bval_bvec,
                DWI.out.b0_and_mask)

            // ** SH fitting if set ** //
            if ( params.sh_fitting ) {
                SH(DWI.out.dwi_bval_bvec)
            }

            // ** Registration of anatomical volume on diffusion volumes. ** //
            REGISTRATION(DTI.out.fa_and_md,
                        ANAT.out.anat_and_mask,
                        DWI.out.b0_and_mask.map{ [it[0], it[1]] })
            
            // ** Extracting b0 ** //
            b0_mask_channel = DWI.out.b0_and_mask
                                .map{[it[0], it[2]]}
            
            // ** Modelling FODF ** //
            FODF(DWI.out.dwi_bval_bvec,
                b0_mask_channel,
                DTI.out.fa_and_md)

            // ** FA channel for tracking maps ** //
            fa_channel = DTI.out.fa_and_md
                .map{[it[0], it[1]]}

            // ** Tracking ** //
            TRACKING(REGISTRATION.out.warped_anat,
                    FODF.out.fodf,
                    fa_channel)
        }

        if ( params.run_connectomics && params.run_tracking ) {
            // ** Fetch tracking data ** //
            tracking = TRACKING.out.trk

            // ** Fetching labels from freesurferflow if -profile freesurfer is used, if not, ** //
            // ** fetching it from input files. ** //
            input = file(params.input)
            if ( !params.run_freesurfer ) {
                labels = Channel.fromFilePairs("$input/**/*labels.nii.gz", size: 1, flat: true)
                            { fetch_id(it.parent, input) }
            } else {
                labels = FREESURFERFLOW.out.labels
            }

            // ** Preparing metrics channel ** //
            dwi_peaks = DWI.out.dwi_bval_bvec
                            .combine(FODF.out.peaks, by: 0)
            fodf = FODF.out.fodf

            def_metrics = DTI.out.fa_and_md
                .combine(DTI.out.ad_and_rd, by: 0)
                .combine(FODF.out.afd_and_nufo, by: 0)
                .map{ sid, fa, md, ad, rd, afd, nufo -> tuple(sid, [fa, md, ad, rd, afd, nufo])}
                .transpose()

            if ( file("$input/**/metrics/*.nii.gz") ) { 
                // ** Default metrics will be used with combined metrics provided in the input folder ** //
                provided_metrics = Channel.fromFilePairs("$input/**/metrics/*.nii.gz", size: -1, flat: false)
                                    { fetch_id(it.parent.parent, input) }
                                    .transpose()

                def_metrics = def_metrics
                                .concat(provided_metrics)
            }

            // ** Flattening metrics channel ** //
            metrics_flat = def_metrics.groupTuple()

            // ** Fetching anat ** //
            t2w = REGISTRATION.out.warped_anat
                        .map{ [it[0], it[1]] }

            // ** Fetching transformation files ** //
            transfos = REGISTRATION.out.transfos

            // ** Launching connectomics workflow ** //
            CONNECTOMICS(tracking,
                        labels,
                        dwi_peaks,
                        fodf,
                        metrics_flat,
                        t2w,
                        transfos)
        }

        if ( params.run_connectomics && !params.run_tracking ) {
            if ( params.infant_config ) {
                data = get_data_connectomics_infant()
            } else {
                data = get_data_connectomics()
            }

            if ( params.run_freesurfer ) {
                labels = FREESURFERFLOW.out.labels
            } else {
                labels = data.labels
            }

            metrics = data.metrics.transpose().groupTuple()

            CONNECTOMICS(data.trk,
                        labels,
                        data.dwi_peaks,
                        data.fodf,
                        metrics,
                        data.t2w,
                        data.transfos)
        }
    }
}

if (!params.help) {
    workflow.onComplete = {
        log.info "Pipeline completed at : $workflow.complete"
        log.info "Execution status : ${ workflow.success ? 'COMPLETED' : 'FAILED'}"
        log.info "Execution duration : $workflow.duration"
    }
}

def display_usage () {
    
    if (params.run_tracking && !params.infant_config && !params.run_connectomics && !params.run_freesurfer ) { 
        usage = file("$projectDir/modules/tracking/USAGE")
    } else if (params.run_tracking && params.infant_config && !params.run_connectomics && !params.run_freesurfer ) {
        usage = file("$projectDir/modules/tracking/USAGE_INFANT")
    } else if (params.run_connectomics && !params.infant_config && !params.run_tracking && !params.run_freesurfer ) {
        usage = file("$projectDir/modules/connectomics/USAGE")
    } else if (params.run_connectomics && params.infant_config && !params.run_tracking && !params.run_freesurfer ) {
        usage = file("$projectDir/modules/connectomics/USAGE_INFANT")
    } else if ( params.run_tracking && params.run_connectomics && !params.infant_config && !params.run_freesurfer ) {
        usage = file("$projectDir/modules/connectomics/USAGE_TRACKING")
    } else if ( params.run_tracking && params.run_connectomics && params.infant_config && !params.run_freesurfer ) {
        usage = file("$projectDir/modules/connectomics/USAGE_TRACKING_INFANT")
    } else if ( params.run_freesurfer && !params.run_tracking && !params.run_connectomics ) {
        usage = file("$projectDir/modules/freesurfer/USAGE")
    } else if ( params.run_freesurfer && !params.run_tracking && params.run_connectomics ) {
        usage = file("$projectDir/modules/freesurfer/USAGE_CONN")
    } else if ( params.run_freesurfer && params.run_tracking && params.run_connectomics ) {
        usage = file("$projectDir/modules/connectomics/USAGE_ALL")
    } else {
        usage = file("$projectDir/USAGE")
    }    

    cpu_count = Runtime.runtime.availableProcessors()
    bindings = ["b0_thr":"$params.b0_thr",
                "skip_dwi_preprocessing":"$params.skip_dwi_preprocessing",
                "initial_bet_f":"$params.initial_bet_f",
                "final_bet_f":"$params.final_bet_f",
                "run_bet_anat":"$params.run_bet_anat",
                "bet_anat_f":"$params.bet_anat_f",
                "topup_config":"$params.topup_config",
                "encoding_direction":"$params.encoding_direction",
                "readout":"$params.readout",
                "topup_prefix":"$params.topup_prefix",
                "eddy_cmd":"$params.eddy_cmd",
                "topup_bet_f":"$params.topup_bet_f",
                "use_slice_drop_correction":"$params.use_slice_drop_correction",
                "dwi_shell_tolerance":"$params.dwi_shell_tolerance",
                "fa_mask_threshold":"$params.fa_mask_threshold",
                "anat_resolution":"$params.anat_resolution",
                "anat_interpolation":"$params.anat_interpolation",
                "mask_interpolation":"$params.mask_interpolation",
                "template_t1":"$params.template_t1",
                "dwi_resolution":"$params.dwi_resolution",
                "dwi_interpolation":"$params.dwi_interpolation",
                "mask_dwi_interpolation":"$params.mask_dwi_interpolation",
                "max_dti_shell_value":"$params.max_dti_shell_value",
                "sh_fitting":"$params.sh_fitting",
                "sh_fitting_order":"$params.sh_fitting_order",
                "sh_fitting_basis":"$params.sh_fitting_basis",
                "min_fodf_shell_value":"$params.min_fodf_shell_value",
                "fodf_metrics_a_facotr":"$params.fodf_metrics_a_factor",
                "max_fa_in_ventricle":"$params.max_fa_in_ventricle",
                "min_md_in_ventricle":"$params.min_md_in_ventricle",
                "relative_threshold":"$params.relative_threshold",
                "basis":"$params.basis",
                "sh_order":"$params.sh_order",
                "mean_frf":"$params.mean_frf",
                "fa":"$params.fa",
                "min_fa":"$params.min_fa",
                "min_nvox":"$params.min_nvox",
                "roi_radius":"$params.roi_radius",
                "set_frf":"$params.set_frf",
                "manual_frf":"$params.manual_frf",
                "number_of_tissues":"$params.number_of_tissues",
                "run_pft_tracking":"$params.run_pft_tracking",
                "pft_compress_streamlines":"$params.pft_compress_streamlines",
                "pft_seeding_mask_type":"$params.pft_seeding_mask_type",
                "pft_fa_seeding_mask_thr":"$params.pft_fa_seeding_mask_thr",
                "pft_algo":"$params.pft_algo",
                "pft_nbr_seeds":"$params.pft_nbr_seeds",
                "pft_seeding":"$params.pft_seeding",
                "pft_step_size":"$params.pft_step_size",
                "pft_theta":"$params.pft_theta",
                "pft_sfthres":"$params.pft_sfthres",
                "pft_sfthres_init":"$params.pft_sfthres_init",
                "pft_min_len":"$params.pft_min_len",
                "pft_max_len":"$params.pft_max_len",
                "pft_particles":"$params.pft_particles",
                "pft_back":"$params.pft_back",
                "pft_front":"$params.pft_front",
                "pft_compress_value":"$params.pft_compress_value",
                "pft_random_seed":"$params.pft_random_seed",
                "run_local_tracking":"$params.run_local_tracking",
                "local_compress_streamlines":"$params.local_compress_streamlines",
                "local_fa_seeding_mask_thr":"$params.local_fa_seeding_mask_thr",
                "local_seeding_mask_type":"$params.local_seeding_mask_type",
                "local_fa_tracking_mask_thr":"$params.local_fa_tracking_mask_thr",
                "local_tracking_mask_type":"$params.local_tracking_mask_type",
                "local_algo":"$params.local_algo",
                "local_seeding":"$params.local_seeding",
                "local_nbr_seeds":"$params.local_nbr_seeds",
                "local_tracking_seed":"$params.local_tracking_seed",
                "local_step_size":"$params.local_step_size",
                "local_theta":"$params.local_theta",
                "local_sfthres":"$params.local_sfthres",
                "local_sfthres_init":"$params.local_sfthres_init",
                "local_min_len":"$params.local_min_len",
                "local_max_len":"$params.local_max_len",
                "local_erosion":"$params.local_erosion",
                "local_compress_value":"$params.local_compress_value",
                "output_dir":"$params.output_dir",
                "processes_denoise_dwi":"$params.processes_denoise_dwi",
                "processes_denoise_t1":"$params.processes_denoise_t1",
                "processes_bet_t1":"$params.processes_bet_t1",
                "processes_eddy":"$params.processes_eddy",
                "processes_registration":"$params.processes_registration",
                "processes_fodf":"$params.processes_fodf",
                "no_pruning":"$params.no_pruning",
                "no_remove_loops":"$params.no_remove_loops",
                "no_remove_outliers":"$params.no_remove_outliers",
                "min_length":"$params.min_length",
                "max_length":"$params.max_length",
                "loop_max_angle":"$params.loop_max_angle",
                "outlier_threshold":"$params.outlier_threshold",
                "run_commit":"$params.run_commit",
                "use_commit2":"$params.use_commit2",
                "commit_on_trk":"$params.commit_on_trk",
                "b_thr":"$params.b_thr",
                "ball_stick":"$params.ball_stick",
                "nbr_dir":"$params.nbr_dir",
                "para_diff":"$params.para_diff",
                "perp_diff":"$params.perp_diff",
                "iso_diff":"$params.iso_diff",
                "processes_commit":"$params.processes_commit",
                "processes_afd_fixel":"$params.processes_afd_fixel",
                "processes_connectivity":"$params.processes_connectivity",
                "references":"$params.references",
                "use_freesurfer_atlas":"$params.use_freesurfer_atlas",
                "use_brainnetome_atlas":"$params.use_brainnetome_atlas",
                "use_glasser_atlas":"$params.use_glasser_atlas",
                "use_schaefer_100_atlas":"$params.use_schaefer_100_atlas",
                "use_schaefer_200_atlas":"$params.use_schaefer_200_atlas",
                "use_schaefer_400_atlas":"$params.use_schaefer_400_atlas",
                "use_lausanne_1_atlas":"$params.use_lausanne_1_atlas",
                "use_lausanne_2_atlas":"$params.use_lausanne_2_atlas",
                "use_lausanne_3_atlas":"$params.use_lausanne_3_atlas",
                "use_lausanne_4_atlas":"$params.use_lausanne_4_atlas",
                "use_lausanne_5_atlas":"$params.use_lausanne_5_atlas",
                "use_dilated_labels":"$params.use_dilated_labels",
                "nb_threads":"$params.nb_threads",
                "atlas_utils_folder":"$params.atlas_utils_folder",
                "compute_FS_BN_GL_SF":"$params.compute_FS_BN_GL_SF",
                "compute_lausanne_multiscale":"$params.compute_lausanne_multiscale",
                "compute_lobes":"$params.compute_lobes",
                "run_freesurfer":"$params.run_freesurfer",
                "run_tracking":"$params.run_tracking",
                "run_connectomics":"$params.run_connectomics",
                "template_config":"$params.template_config",
                "processes":"$params.processes",
                "cpu_count":"$cpu_count"
                ]

    engine = new groovy.text.SimpleTemplateEngine()
    template = engine.createTemplate(usage.text).make(bindings)

    print template.toString()
}

def display_run_info () {
    log.info ""
    log.info "Infant-DWI pipeline"
    log.info "========================"
    log.info "Pipeline adapted from the SCIL Tractoflow pipeline " 
    log.info "(https://github.com/scilus/tractoflow.git) and the "
    log.info "Connectoflow Pipeline (https://github.com/scilus/connectoflow.git)."
    log.info "Made for use on newborn diffusion MRI data."
    log.info ""
    log.info "Start time: $workflow.start"
    log.info ""

    log.debug "[Command-line]"
    log.debug "$workflow.commandLine"
    log.debug ""

    log.info "[Git Info]"
    log.info "$workflow.repository - $workflow.revision [$workflow.commitId]"
    log.info ""

    log.info "[Inputs]"
    log.info "Input: $params.input"
    log.info "Output Directory: $params.output_dir"
    log.info ""

    if ( params.run_tracking ) {
        log.info "[Tracking Options]"
        log.info ""
        log.info "GLOBAL OPTIONS"
        log.info "Threshold for b0: $params.b0_thr"
        log.info "DWI Shell Tolerance: $params.dwi_shell_tolerance"
        log.info ""
        log.info "BET DWI OPTIONS"
        log.info "Initial fractional value for BET: $params.initial_bet_f"
        log.info "Finale fractional value for BET: $params.final_bet_f"
        log.info ""
        log.info "BET T2W OPTIONS"
        log.info "Run BET on T2W image: $params.run_bet_anat"
        log.info "Fractional value for T2W BET: $params.bet_anat_f"
        log.info ""
        log.info "EDDY AND TOPUP OPTIONS"
        log.info "Configuration for topup: $params.topup_config"
        log.info "Encoding direction: $params.encoding_direction"
        log.info "Readout: $params.readout"
        log.info "Topup prefix: $params.topup_prefix"
        log.info "Topup BET fractional value: $params.topup_bet_f"
        log.info "Eddy command: $params.eddy_cmd"
        log.info "Run slice drop correction: $params.use_slice_drop_correction"
        log.info ""
        log.info "NORMALIZE OPTIONS"
        log.info "FA threshold for masking: $params.fa_mask_threshold"
        log.info ""
        log.info "RESAMPLE ANAT OPTIONS"
        log.info "Resampling resolution for Anatomical file: $params.anat_resolution"
        log.info "Interpolation method for Anatomical file: $params.anat_interpolation"
        log.info "Interpolation method for masks: $params.mask_interpolation"
        log.info ""
        log.info "RESAMPLE DWI OPTIONS"
        log.info "Resampling resolution for DWI: $params.dwi_resolution"
        log.info "Interpolation method for DWI: $params.dwi_interpolation"
        log.info "Interpolation method for DWI mask: $params.mask_dwi_interpolation"
        log.info ""
        log.info "EXTRACT DWI SHELLS OPTIONS"
        log.info "Maximum DTI shell value: $params.max_dti_shell_value"
        log.info ""
        log.info "SH FITTING OPTIONS"
        log.info "Run SH fitting: $params.sh_fitting"
        log.info "SH fitting order: $params.sh_fitting_order"
        log.info "SH fitting basis: $params.sh_fitting_basis"
        log.info ""
        log.info "FODF OPTIONS"
        log.info "Minimum fODF shell value: $params.min_fodf_shell_value"
        log.info "Maximum FA value in ventricles: $params.max_fa_in_ventricle"
        log.info "Minimum MD value in ventricles: $params.min_md_in_ventricle"
        log.info "Relative threshold (RT): $params.relative_threshold"
        log.info "SH basis: $params.basis"
        log.info "SH order: $params.sh_order"
        log.info ""
        log.info "FRF OPTIONS"
        log.info "Run mean FRF: $params.mean_frf"
        log.info "FA threshold for single fiber voxel: $params.fa"
        log.info "Minimum FA for selecting voxel: $params.min_fa"
        log.info "Minimum number of voxels: $params.min_nvox"
        log.info "ROI radius: $params.roi_radius"
        log.info "Set FRF: $params.set_frf"
        log.info "Manual FRF: $params.manual_frf"
        log.info ""
        log.info "SEEDING AND TRACKING OPTIONS"
        log.info "Local tracking : $params.run_local_tracking"
        log.info "PFT tracking: $params.run_pft_tracking"

        if ( params.run_pft_tracking ) {
            log.info "Algorithm for tracking: $params.pft_algo"
            log.info "Number of seeds per voxel: $params.pft_nb_seeds"
            log.info "Seeding method: $params.pft_seeding"
            log.info "Step size: $params.pft_step_size"
            log.info "Theta threshold: $params.pft_theta"
            log.info "Minimum fiber length: $params.pft_min_len"
            log.info "Maximum fiber length: $params.pft_max_len"
            log.info "Compression: $params.pft_compress_streamlines"
        }
        else {
            log.info "Algorithm for tracking: $params.local_algo"
            log.info "Number of seeds per voxel: $params.local_nb_seeds"
            log.info "Seeding method: $params.local_seeding"
            log.info "Step size: $params.local_step_size"
            log.info "Theta threshold: $params.local_theta"
            log.info "Minimum fiber length: $params.local_min_len"
            log.info "Maximum fiber length: $params.local_max_len"
            log.info "Compression: $params.local_compress_streamlines"
        }

        log.info ""
        log.info "PROCESSES PER TASKS"
        log.info "Processes for denoising DWI: $params.processes_denoise_dwi"
        log.info "Processes for EDDY: $params.processes_eddy"
        log.info "Processes for registration: $params.processes_registration"
        log.info "Processes for FODF: $params.processes_fodf"
        log.info ""
    }

    if ( params.run_connectomics ) {
        log.info "[Connectomics Options]"
        log.info ""
        log.info "DECOMPOSE OPTIONS"
        log.info "No pruning: $params.no_pruning"
        log.info "No remove loops: $params.no_remove_loops"
        log.info "No remove outliers: $params.no_remove_outliers"
        log.info "Minimal outlier length: $params.min_length"
        log.info "Maximal outlier lenght: $params.max_length"
        log.info "Maximum looping angle: $params.loop_max_angle"
        log.info ""
        log.info "COMMIT OPTIONS"
        log.info "Number of directions: $params.nbr_dir"
        log.info "Parallel diffusivity: $params.para_diff"
        log.info "Isotropic diffusivity: $params.iso_diff"
        log.info ""
        log.info "PROCESSES OPTIONS"
        log.info "Number of processes for COMMIT: $params.processes_commit"
        log.info "Number of processes for AFD_FIXEL: $params.processes_afd_fixel"
        log.info "Number of processes for CONNECTIVITY: $params.processes_connectivity"
        log.info "" 
    }
}